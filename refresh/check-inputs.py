# The release and refresh jobs use this one conservative input proof.
import datetime, io, json, os, pathlib, re, subprocess, tempfile, urllib.parse, zipfile
def command(*args):
    return subprocess.check_output(args, timeout=15, stderr=subprocess.PIPE)
def api(path):
    return json.loads(command('gh', 'api', 'repos/' + os.environ['GH_REPO'] + '/' + path))
output = pathlib.Path(os.environ['GITHUB_OUTPUT'])
with output.open('a') as stream:
    stream.write('route=full\n')
try:
    # GitHub's public git refs and REST APIs need no checkout or app token.
    refs = command('git', 'ls-remote', 'https://github.com/vanillagreencom/kendex.git',
                   'refs/heads/main', 'refs/tags/v1.*').decode().splitlines()
    main = [row.split()[0] for row in refs if row.split()[1] == 'refs/heads/main']
    tags = sorted(row for row in refs if re.fullmatch(r'refs/tags/v1\.[0-9]+\.[0-9]+(?:\^\{\})?', row.split()[1]))
    head = api('commits/' + urllib.parse.quote(os.environ['DEFAULT_BRANCH'], safe=''))['sha']
    assert len(main) == 1 and tags
    assert all(re.fullmatch('[0-9a-f]{40}', sha) for sha in (main[0], head, os.environ['WORKFLOW_SHA']))
    inputs = dict(catalog=main[0], workflow=os.environ['WORKFLOW_SHA'], tags=tags, consumer=head)
    current = dict(inputs=inputs, run=int(os.environ['GITHUB_RUN_ID']), attempt=int(os.environ['GITHUB_RUN_ATTEMPT']))
    assert current['run'] > 0 and current['attempt'] > 0
    record = pathlib.Path(tempfile.mkdtemp(prefix='kendex-refresh-', dir=os.environ['RUNNER_TEMP'])) / 'record.json'
    record.write_text(json.dumps(current, sort_keys=True))
    with output.open('a') as stream:
        stream.write('record-path=' + str(record) + '\n')
    owner = os.environ['GH_REPO'].split('/')[0]
    query = urllib.parse.urlencode(dict(state='all', head=owner + ':kendex/refresh', per_page=100))
    pages = json.loads(command('gh', 'api', '--paginate', '--slurp', 'repos/' + os.environ['GH_REPO'] + '/pulls?' + query))
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
    pulls = [pr for page in pages for pr in page]
    # Only the render step closes, pushes, re-describes or arms an
    # open rolling pull request, so one keeps the full path.
    if any(pr['state'] == 'open' for pr in pulls):
        print('refresh-check=full cause=open-pull-request')
        raise SystemExit(0)
    # The review step reads a pull request merged in this window.
    reviews = any(pr['merged_at'] and datetime.datetime.fromisoformat(pr['merged_at'].replace('Z', '+00:00')) >= cutoff
                  for pr in pulls)
    artifacts = api('actions/artifacts?name=kendex-refresh-current&per_page=100')['artifacts']
    # A fork or feature-branch artifact cannot attest the default branch.
    artifacts = [a for a in artifacts if not a['expired'] and
                 a['workflow_run']['head_branch'] == os.environ['DEFAULT_BRANCH'] and
                 a['workflow_run']['head_repository_id'] == a['workflow_run']['repository_id']]
    latest = max(artifacts, key=lambda a: a['created_at'])
    archive = command('gh', 'api', 'repos/' + os.environ['GH_REPO'] + '/actions/artifacts/' + str(latest['id']) + '/zip')
    with zipfile.ZipFile(io.BytesIO(archive)) as saved:
        previous = json.loads(saved.read('record.json'))
    run = api('actions/runs/' + str(latest['workflow_run']['id']))
    assert run['conclusion'] == 'success' and run['path'] == '.github/workflows/kendex-refresh.yml'
    # Reruns keep their run ID and can retain earlier attempts' artifacts.
    # A newer attempt without its own record cannot reuse that proof.
    assert type(previous['attempt']) is int and previous['attempt'] > 0
    assert previous['run'] == run['id'] and previous['attempt'] == run['run_attempt']
    saved_at = datetime.datetime.fromisoformat(latest['created_at'].replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    assert datetime.timedelta(0) <= now - saved_at <= datetime.timedelta(hours=24)
    # GitHub allows rerun requests for 30 days, then waiting or running for 35.
    # Read that whole window, independent of list order. Partition it
    # so busy hourly callers stay below GitHub's 1,000-result search cap.
    start = saved_at - datetime.timedelta(days=65)
    history = {}
    while start < now:
        end = min(start + datetime.timedelta(days=7), now)
        query = urllib.parse.urlencode(dict(branch=os.environ['DEFAULT_BRANCH'],
                                            created=start.isoformat() + '..' + end.isoformat(), per_page=100))
        pages = json.loads(command('gh', 'api', '--paginate', '--slurp',
                                  'repos/' + os.environ['GH_REPO'] + '/actions/workflows/kendex-refresh.yml/runs?' + query))
        batch = [recent for page in pages for recent in page['workflow_runs']]
        assert 0 <= pages[0]['total_count'] == len(batch) < 1000
        assert len({recent['id'] for recent in batch}) == len(batch)
        for recent in batch:
            assert recent['id'] not in history or history[recent['id']] == recent
            history[recent['id']] = recent
        start = end
    assert run['id'] in history
    assert current['attempt'] == 1
    for recent in history.values():
        if recent['id'] == current['run']:
            assert recent['run_attempt'] == current['attempt']
            continue
        if recent['id'] == run['id']:
            assert recent['run_attempt'] == previous['attempt']
            continue
        if datetime.datetime.fromisoformat(recent['updated_at'].replace('Z', '+00:00')) < saved_at:
            continue
        # Latest-attempt jobs cannot prove what an earlier attempt did.
        # Keep rerun history on the full path instead of walking attempts.
        assert type(recent['run_attempt']) is int and recent['run_attempt'] == 1
        assert recent['status'] == 'completed' and recent['conclusion'] == 'success'
        report = api('actions/runs/' + str(recent['id']) + '/attempts/1/jobs?per_page=100')
        jobs = report['jobs']
        assert report['total_count'] == len(jobs)
        # A review-only run checks out and installs too, so only its
        # skipped render step proves it left the record's render alone.
        steps = [step for job in jobs for step in job.get('steps', [])]
        renders = [step['conclusion'] for step in steps if step['name'] == 'Refresh and arm the rolling pull request']
        if renders:
            assert [step['conclusion'] for step in steps if step['name'] == 'refresh-input-check'] == ['success']
            assert [step['conclusion'] for step in steps if step['name'] == 'Refresh and arm the rolling pull request'] == ['skipped']
        else:
            # A new caller skips the entire refresh job. Its release
            # check plus no other executed jobs proves no render;
            # it supplies no new current record or render attestation.
            release = [job for job in jobs if any(step['name'] == 'release-input-check' and
                       step['conclusion'] == 'success' for step in job.get('steps', []))]
            assert len(release) == 1 and release[0]['conclusion'] == 'success'
            skipped = [job for job in jobs if job is not release[0]]
            assert all(job['conclusion'] == 'skipped' and not job.get('steps') for job in skipped)
    if previous['inputs'] != inputs:
        print('refresh-check=full cause=changed')
    else:
        route = 'reviews' if reviews else 'skip'
        with output.open('a') as stream:
            stream.write('route=' + route + '\n')
        print('refresh-check=' + route + ' cause=current')
except (AssertionError, AttributeError, IndexError, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile):
    # Missing grants, expired artifacts and failed reads cannot authorize a skip.
    print('refresh-check=full cause=unreadable')
