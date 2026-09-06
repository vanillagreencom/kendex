# Privacy Policy

Version 1. Effective 6 September 2026.

This policy covers the kendex desktop app, the kendex command-line tool, and kendex.ai. The controller is Vanillagreen LLC of Bellevue, Washington, USA.

## The app and the CLI collect nothing

There is no telemetry, no analytics, no crash reporting and no install identifier in the desktop app or the command-line tool. We do not know who has kendex installed or what they installed with it. Signing in is the one thing that changes what leaves your machine, and **When you sign in** below says what.

Your projects, packages, settings, lock files and scan results are files on your own computer. kendex reads and writes them there and uploads none of them.

Your acceptance of these documents is recorded in kendex's settings file on your own computer, as the version accepted and the date. It goes nowhere else.

The app and the CLI do make network requests. Signed out, they go to kendex.ai for the community directory and for the skills.sh listings it proxies, to skills.sh for a search you type, to GitHub for kendex's own releases, and to whichever host a package's source repository lives on. None of them carries an account, a credential or an identifier, and none carries your code. What a search sends is the words you typed. A package is fetched from its author's own repository, so that host sees the request and we do not.

## kendex.ai, signed out

You can browse the site and read the directory without an account.

We run no analytics on it: no Google Analytics, no Vercel Analytics, no session recording, no advertising pixel, no third-party tracker, and no analytics or advertising cookies.

## When you sign in

Signing in is optional. It is needed only to submit a marketplace, manage one you own, or create a collection. Sign-in is through GitHub. We ask GitHub for `read:user` and `user:email` and nothing more, so we cannot read your private code.

Once you are signed in, the app and the CLI do send a credential that names your account: signing in and out, reading who you are, submitting a repository and reading your submissions, and opening a collection link. `kendex login` is what starts that; before it there is nothing to send. A submission also asks GitHub about the repository you named.

We store:

- your account, which is the name, email address and avatar image URL GitHub gives us;
- your GitHub link, which is your GitHub account identifier, the scopes you granted, and the OAuth tokens GitHub issued, encrypted at rest;
- your session, which is a session token and when it expires;
- your machine tokens: `kendex login` stores a hash of each token, never the token itself, with what it may do and when it expires, and the same for the short-lived sign-in codes;
- what you submitted, which is the repository, that you are the submitter, and the result of each index run;
- your collections, which are a name, a description and their members. Deleting a collection stops its link working and keeps the row.

## Rate limits and server logs

We count requests to stop abuse. A counter holds one key, which is an IP address as our host reports it, an account, or a sign-in code, along with the time its window opened and how many attempts it has seen.

Every request to kendex.ai reaches Vercel, our host, which logs what any web server logs: the IP address, the URL, the time, the response status and the user-agent. How long Vercel keeps those logs is their setting rather than ours.

## Who else sees it

We do not sell your data, share it for advertising, or use it to train any model.

Vercel hosts the site and Neon holds the database; both process data on our behalf. GitHub and skills.sh are separate controllers under their own policies: GitHub when you sign in, when kendex fetches a release or a package hosted there, and when you file an issue through `kendex report`; skills.sh when kendex searches it. A package hosted anywhere else reaches you from that host under its own policy.

We may disclose data where the law requires it.

## How long we keep it

Sessions, machine tokens and sign-in codes expire on their own, and a revoked token is refused from the next request onward. Rate-limit counters hold one window and are overwritten. Your account, your collections and what you submitted stay until you ask us to delete them. Server logs are kept for whatever period Vercel sets.

## Your rights

You can ask for a copy of your data, ask us to correct or delete it, or object to what we do with it. Email us, and we will check who you are first, normally by asking you to reply from the address on the account.

## Changes to this policy

If we change this policy, we change the version and the date at the top and publish the new text.

## Contact

brad@vanillagreen.com
