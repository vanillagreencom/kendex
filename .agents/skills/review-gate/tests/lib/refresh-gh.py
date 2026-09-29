#!/usr/bin/env python3
"""Persistent GitHub and change-class fixture for the refresh-review writer's process tests."""
import json
import os
from pathlib import Path
import sys

path = Path(os.environ['GH_FIXTURE'])
world = json.loads(path.read_text())
if sys.argv[1:2] == ['classify']:
    # Neither credential reaches the classifier.
    assert 'KENDEX_ISSUES_TOKEN' not in os.environ
    assert 'GH_TOKEN' not in os.environ
    flags = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    assert flags['--event'] == 'pull_request' and flags['--repo'] == os.environ['EXPECT_REPO']
    pr = next(p for p in world['prs'] if p['head']['sha'] == flags['--head'])
    assert flags['--base'] == pr['base']['sha']
    world.setdefault('proofs', []).append(pr['number'])
    path.write_text(json.dumps(world))
    if pr.get('class') == 'error':
        sys.exit(2)
    # change-class's stderr class: line carries measured= and the cause.
    answer = pr.get('class', 'change_class=render')
    measured = str(pr.get('measured', True)).lower()
    print(f"class: class={answer.removeprefix('change_class=')} measured={measured} cause={pr.get('cause', 'fixture')}",
          file=sys.stderr)
    print(answer)
    sys.exit(0)

args = sys.argv[1:]
assert args.pop(0) == 'api'
assert os.environ['GH_TOKEN'] == 'fixture-token'
fields = {}
method = 'GET'
endpoint = None
while args:
    arg = args.pop(0)
    if arg in ('-f', '-F'):
        key, value = args.pop(0).split('=', 1)
        fields[key] = value
    elif arg == '-X':
        method = args.pop(0)
    elif arg == '--paginate':
        pass
    elif endpoint is None:
        endpoint = arg
    else:
        raise AssertionError((arg, endpoint))

kind = None
pr = None
if endpoint == 'graphql':
    query = fields['query']
    if query.startswith('mutation'):
        kind = 'resolve'
        pr = next(p for p in world['prs'] if any(t['id'] == fields['id'] for t in p['threads']))
    else:
        kind = 'threads'
        assert '$endCursor:String' in query and 'after:$endCursor' in query
        assert '--paginate' in sys.argv
        pr = next(p for p in world['prs'] if p['number'] == int(fields['number']))
elif endpoint.startswith('repos/acme/repo/pulls?'):
    kind = 'pulls'
    assert 'state=all' in endpoint and 'head=acme:kendex/refresh' in endpoint
elif endpoint.startswith('repos/acme/repo/'):
    parts = endpoint.split('/')
    pr = next(p for p in world['prs'] if p['number'] == int(parts[4]))
    if len(parts) == 5:
        kind = 'pull'
    elif parts[-1] == 'replies':
        kind = 'reply'
    elif parts[3] == 'pulls' and parts[5].startswith('comments?'):
        kind = 'review-comments'
    else:
        raise AssertionError(endpoint)
else:
    raise AssertionError(endpoint)

failure = world.get('failure', {})
if failure.get('kind') == kind:
    mode = failure['mode']
    if mode == 'error':
        sys.exit(1)
    if mode == 'empty':
        sys.exit(0)
    if mode == 'object':
        print('{}')
        sys.exit(0)

if kind == 'pulls':
    # Two output pages exercise the production slurp rather than the shim.
    for p in world['prs']:
        print(json.dumps([{k: p[k] for k in ('number', 'state', 'head', 'base', 'user', 'merged_at')}]))
elif kind == 'pull':
    result = {k: pr[k] for k in ('head', 'base')}
    if failure.get('mode') == 'moved':
        result['head']['sha'] = 'd' * 40
    print(json.dumps(result))
elif kind == 'review-comments':
    print(json.dumps(pr['comments']))
elif kind == 'threads':
    nodes = [{'id': t['id'], 'isResolved': t['resolved'], 'comments': {'nodes': [{'databaseId': t['root']}]}} for t in pr['threads']]
    pages = [nodes[:1], nodes[1:]] if len(nodes) > 1 else [nodes]
    for index, nodes in enumerate(pages):
        next_page = index < len(pages) - 1 or failure.get('mode') == 'unfinished'
        print(json.dumps({'data': {'repository': {'pullRequest': {'reviewThreads': {
            'nodes': nodes, 'pageInfo': {'hasNextPage': next_page, 'endCursor': str(index) if next_page else None}
        }}}}}))
else:
    world.setdefault('writes', []).append({'kind': kind, 'pr': pr['number'], **fields})
    if kind == 'reply':
        root = int(endpoint.split('/')[-2])
        comment = {'id': 1000 + len(world['writes']), 'user': pr['user'], 'body': fields['body'],
                   'in_reply_to_id': root, 'path': next(c['path'] for c in pr['comments'] if c['id'] == root)}
        pr['comments'].append(comment)
        result = comment
    elif kind == 'resolve':
        thread = next(t for t in pr['threads'] if t['id'] == fields['id'])
        thread['resolved'] = True
        result = {'data': {'resolveReviewThread': {'thread': {'id': thread['id'], 'isResolved': True}}}}
    else:
        raise AssertionError(kind)
    path.write_text(json.dumps(world))
    print(json.dumps(result))
