# Notsus AWS notes

This folder tracks AWS-facing defaults for the Notsus Crewrift Prime reports.

Current local tool defaults:

- Bucket: `crewrift-prime-tournament`
- Prefix: `notsus`
- Profile: `tournament`
- Website path: `http://crewrift-prime-tournament.s3-website-us-east-1.amazonaws.com/notsus/`

Generate without publishing:

```sh
nim r players/notsus/tools/tournament.nim -- --update --no-s3-sync
```

Publish with the default bucket and prefix:

```sh
nim r players/notsus/tools/tournament.nim -- --update
```
