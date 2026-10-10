# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's private reporting instead: **Security** tab, then **Report a vulnerability**.

Include what you found, how to reproduce it and the Pruner version. You can expect a first reply within a few days.

## Scope

Pruner runs with administrator rights and changes system settings, so these are in scope:

- Anything that lets another program or user make Pruner run code it should not.
- Deleting files or changing settings outside what the interface shows.
- Unsafe handling of paths, links or file names.

Out of scope: warnings from antivirus products about unsigned tools that modify system settings, and risks that come from options you deliberately turn on (for example disabling Defender).

## Supported versions

Only the latest release receives fixes.
