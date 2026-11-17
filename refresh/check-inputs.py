# The release and refresh jobs use this one conservative input proof.
import datetime, io, json, os, pathlib, re, subprocess, tempfile, time, urllib.parse, zipfile
proof = 'output'
# Release has five minutes including cancellation and checkout; reserve two
# for those steps and completion so unreadable proof can still return full.
deadline = time.monotonic() + 180
def command(*args):
    # Fleet's 636-run history read took 14.5s at the old 15s bound (KEN-5181).
    # Keep complete pagination bounded separately from single-object reads.
    timeout = 120 if '--paginate' in args and '--slurp' in args else 15
    started = time.monotonic()
    remaining = deadline - started
    try:
        if remaining <= 0:
            raise subprocess.TimeoutExpired(args, 0)
        return subprocess.check_output(args, timeout=min(timeout, remaining), stderr=subprocess.PIPE)
    finally:
        if args[:2] == ('gh', 'api'):
            print(f'refresh-read proof={proof} seconds={time.monotonic() - started:.3f} path={args[-1]}')
def api(path, name):
    global proof
    proof = name
    return json.loads(command('gh', 'api', 'repos/' + os.environ['GH_REPO'] + '/' + path))
output = pathlib.Path(os.environ['GITHUB_OUTPUT'])
with output.open('a') as stream:
    stream.write('route=full\n')
try:
    # GitHub's public git refs and REST APIs need no checkout or app token.
    proof = 'catalog-refs'
    refs = command('git', 'ls-remote', 'https://github.com/vanillagreencom/kendex.git',
                   'refs/heads/main', 'refs/tags/v1.*').decode().splitlines()
    main = [row.split()[0] for row in refs if row.split()[1] == 'refs/heads/main']
    tags = sorted(row for row in refs if re.fullmatch(r'refs/tags/v1\.[0-9]+\.[0-9]+(?:\^\{\})?', row.split()[1]))
    head = api('commits/' + urllib.parse.quote(os.environ['DEFAULT_BRANCH'], safe=''), 'consumer-head')['sha']
    assert len(main) == 1 and tags, 'catalog-refs'
    assert all(re.fullmatch('[0-9a-f]{40}', sha) for sha in (main[0], head, os.environ['WORKFLOW_SHA'])), 'input-shas'
    inputs = dict(catalog=main[0], workflow=os.environ['WORKFLOW_SHA'], tags=tags, consumer=head)
    proof = 'current-identity'
    current = dict(inputs=inputs, run=int(os.environ['GITHUB_RUN_ID']), attempt=int(os.environ['GITHUB_RUN_ATTEMPT']))
    assert current['run'] > 0 and current['attempt'] > 0, 'current-identity'
    proof = 'record-write'
    record = pathlib.Path(tempfile.mkdtemp(prefix='kendex-refresh-', dir=os.environ['RUNNER_TEMP'])) / 'record.json'
    record.write_text(json.dumps(current, sort_keys=True))
    with output.open('a') as stream:
        stream.write('record-path=' + str(record) + '\n')
    owner = os.environ['GH_REPO'].split('/')[0]
    query = urllib.parse.urlencode(dict(state='all', head=owner + ':kendex/refresh', per_page=100))
    proof = 'pull-requests'
    pages = json.loads(command('gh', 'api', '--paginate', '--slurp', 'repos/' + os.environ['GH_REPO'] + '/pulls?' + query))
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
    proof = 'pull-request-state'
    pulls = [pr for page in pages for pr in page]
    # Only the render step closes, pushes, re-describes or arms an
    # open rolling pull request, so one keeps the full path.
    if any(pr['state'] == 'open' for pr in pulls):
        print('refresh-check=full cause=open-pull-request')
        raise SystemExit(0)
    # The review step reads a pull request merged in this window.
    reviews = any(pr['merged_at'] and datetime.datetime.fromisoformat(pr['merged_at'].replace('Z', '+00:00')) >= cutoff
                  for pr in pulls)
    artifacts = api('actions/artifacts?name=kendex-refresh-current&per_page=100', 'artifact-list')['artifacts']
    # A fork or feature-branch artifact cannot attest the default branch.
    proof = 'artifact-origin'
    artifacts = [a for a in artifacts if not a['expired'] and
                 a['workflow_run']['head_branch'] == os.environ['DEFAULT_BRANCH'] and
                 a['workflow_run']['head_repository_id'] == a['workflow_run']['repository_id']]
    proof = 'record-available'
    latest = max(artifacts, key=lambda a: a['created_at'])
    proof = 'record-download'
    archive = command('gh', 'api', 'repos/' + os.environ['GH_REPO'] + '/actions/artifacts/' + str(latest['id']) + '/zip')
    proof = 'record-archive'
    with zipfile.ZipFile(io.BytesIO(archive)) as saved:
        previous = json.loads(saved.read('record.json'))
    run = api('actions/runs/' + str(latest['workflow_run']['id']), 'record-run')
    assert run['conclusion'] == 'success' and run['path'] == '.github/workflows/kendex-refresh.yml', 'record-workflow'
    # Reruns keep their run ID and can retain earlier attempts' artifacts.
    # A newer attempt without its own record cannot reuse that proof.
    assert type(previous['attempt']) is int and previous['attempt'] > 0, 'record-attempt'
    assert previous['run'] == run['id'] and previous['attempt'] == run['run_attempt'], 'record-identity'
    proof = 'record-age'
    saved_at = datetime.datetime.fromisoformat(latest['created_at'].replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    assert datetime.timedelta(0) <= now - saved_at <= datetime.timedelta(hours=24), 'record-age'
    # GitHub allows rerun requests for 30 days, then waiting or running for 35.
    # Read that whole window, independent of list order. Partition it
    # so busy hourly callers stay below GitHub's 1,000-result search cap.
    start = saved_at - datetime.timedelta(days=65)
    history = {}
    while start < now:
        end = min(start + datetime.timedelta(days=7), now)
        query = urllib.parse.urlencode(dict(branch=os.environ['DEFAULT_BRANCH'],
                                            created=start.isoformat() + '..' + end.isoformat(), per_page=100))
        proof = 'history-window'
        pages = json.loads(command('gh', 'api', '--paginate', '--slurp',
                                  'repos/' + os.environ['GH_REPO'] + '/actions/workflows/kendex-refresh.yml/runs?' + query))
        proof = 'history-page'
        batch = [recent for page in pages for recent in page['workflow_runs']]
        assert 0 <= pages[0]['total_count'] == len(batch) < 1000, 'history-count'
        assert len({recent['id'] for recent in batch}) == len(batch), 'history-unique'
        for recent in batch:
            assert recent['id'] not in history or history[recent['id']] == recent, 'history-overlap'
            history[recent['id']] = recent
        start = end
    assert run['id'] in history, 'record-in-history'
    assert current['attempt'] == 1, 'current-first-attempt'
    for recent in history.values():
        proof = 'history-run'
        if recent['id'] == current['run']:
            assert recent['run_attempt'] == current['attempt'], 'current-history-attempt'
            continue
        if recent['id'] == run['id']:
            assert recent['run_attempt'] == previous['attempt'], 'record-history-attempt'
            continue
        if datetime.datetime.fromisoformat(recent['updated_at'].replace('Z', '+00:00')) < saved_at:
            continue
        # Latest-attempt jobs cannot prove what an earlier attempt did.
        # Keep rerun history on the full path instead of walking attempts.
        assert type(recent['run_attempt']) is int and recent['run_attempt'] == 1, 'history-first-attempt'
        assert recent['status'] == 'completed' and recent['conclusion'] == 'success', 'history-success'
        report = api('actions/runs/' + str(recent['id']) + '/attempts/1/jobs?per_page=100', 'history-jobs')
        jobs = report['jobs']
        assert report['total_count'] == len(jobs), 'jobs-count'
        # A review-only run checks out and installs too, so only its
        # skipped render step proves it left the record's render alone.
        proof = 'job-steps'
        steps = [step for job in jobs for step in job.get('steps', [])]
        renders = [step['conclusion'] for step in steps if step['name'] == 'Refresh and arm the rolling pull request']
        if renders:
            assert [step['conclusion'] for step in steps if step['name'] == 'refresh-input-check'] == ['success'], 'refresh-check-success'
            assert [step['conclusion'] for step in steps if step['name'] == 'Refresh and arm the rolling pull request'] == ['skipped'], 'render-skipped'
        else:
            # A new caller skips the entire refresh job. Its release
            # check plus no other executed jobs proves no render;
            # it supplies no new current record or render attestation.
            release = [job for job in jobs if any(step['name'] == 'release-input-check' and
                       step['conclusion'] == 'success' for step in job.get('steps', []))]
            assert len(release) == 1 and release[0]['conclusion'] == 'success', 'release-check-success'
            skipped = [job for job in jobs if job is not release[0]]
            assert all(job['conclusion'] == 'skipped' and not job.get('steps') for job in skipped), 'other-jobs-skipped'
    proof = 'record-inputs'
    if previous['inputs'] != inputs:
        print('refresh-check=full cause=changed')
    else:
        route = 'reviews' if reviews else 'skip'
        with output.open('a') as stream:
            stream.write('route=' + route + '\n')
        print('refresh-check=' + route + ' cause=current')
except (AssertionError, AttributeError, IndexError, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
    # Missing grants, expired artifacts and failed reads cannot authorize a skip.
    failed = str(error) if isinstance(error, AssertionError) else proof
    print('refresh-check=full cause=unreadable proof=' + failed + ' exception=' + type(error).__name__)
