# Anands Storage

Branded [SeaweedFS](https://github.com/seaweedfs/seaweedfs) for s3.anands.xyz / s3-admin.anands.xyz.
Orange / black / grey theme, Anands "A" logo, favicon, "Anands Storage" naming, and optional
Authentik (OIDC) single sign-on in front of the Admin UI.

## How it works
The Admin UI is compiled into the `weed` binary, so it cannot be themed from outside the image.
The Dockerfile clones SeaweedFS at a pinned tag (`SEAWEED_REF`), runs `scripts/apply-brand.mjs`
(copies `brand/` assets, rewrites titles/navbar/login, appends `brand/brand.css`), then builds `weed`.
Every patch asserts it matched, so an upstream change fails the build instead of shipping half-branded.
The image keeps upstream's layout (`/usr/bin/weed`, `/entrypoint.sh`, `/data`), so it is a drop-in
replacement for `chrislusf/seaweedfs:<tag>`: **same volumes, same commands, no data touched.**

## Deploy (keeps your data)
1. Push to `anandnms2/anands-storage`; the workflow builds `ghcr.io/anandnms2/anands-storage:latest`
   (set the GHCR package to public, or add GHCR credentials in Coolify).
2. Coolify > service "Anands S3 Storage" > Edit Compose: change `image:` of **both** `seaweedfs-admin`
   and `seaweedfs-master` from `chrislusf/seaweedfs:4.13` to `ghcr.io/anandnms2/anands-storage:latest`
   (keeping the master on the same build keeps versions in lockstep). Leave volumes, commands, env and domains alone.
3. Save and Deploy. Hard-refresh the browser.
4. Rollback: set `image:` back to `chrislusf/seaweedfs:4.13`.

## SSO for the Admin UI (Authentik)
Add these env vars to the `seaweedfs-admin` container only. If any is missing, SSO is off and the
normal admin username/password login keeps working.

| Variable | Value |
|---|---|
| `ANANDS_SSO_ISSUER_URL` | `https://sso.anands.xyz/application/o/<slug>/` |
| `ANANDS_SSO_CLIENT_ID` | from the Authentik OAuth2/OIDC provider |
| `ANANDS_SSO_CLIENT_SECRET` | from the Authentik provider |
| `ANANDS_SSO_REDIRECT_URL` | `https://s3-admin.anands.xyz/oauth2/callback` |
| `ANANDS_SSO_COOKIE_SECRET` | 32 random chars (`openssl rand -hex 16`) |
| `ANANDS_SSO_ALLOWED_EMAILS` | optional, comma-separated allow-list (otherwise Authentik's app bindings decide) |

In Authentik: create an OAuth2/OpenID provider (confidential, redirect URI above, scopes openid/profile/email),
an Application using it, and bind only the users/groups who may administer storage.

When on: oauth2-proxy listens on the admin's public port, the real admin moves to `127.0.0.1:<port+20000>`,
and the admin's own login is disabled (SSO replaces it). 
### Login / logout links (SSO on)
| Link | Does |
|---|---|
| `https://s3-admin.anands.xyz/oauth2/start?rd=/` | **Direct login hotlink**: goes straight to Authentik (no button). Change `rd` to deep-link, e.g. `rd=/cluster/volumes`. |
| `https://s3-admin.anands.xyz/login` | Same, redirects to the hotlink above |
| `https://s3-admin.anands.xyz/logout` | **Logout**: clears the admin session and ends the Authentik session (navbar "Logout" uses this) |
| `https://s3-admin.anands.xyz/oauth2/sign_out` | Raw proxy sign-out (admin session only) |

Any protected page also bounces unauthenticated visitors straight to Authentik, so plain deep links work as hotlinks.
Optional: `ANANDS_SSO_END_SESSION_URL` overrides the Authentik end-session URL (default: issuer URL + `end-session/`);
set it to `none` to sign out of the admin only and keep the Authentik session.
The S3 API (port 8333) and master are not affected.

## Upgrading SeaweedFS
Run the workflow manually with `seaweed_ref` set to the new tag (or change the default in `Dockerfile`
and `build.yml`), then redeploy.

## Automatic weekly upgrade
`.github/workflows/upgrade.yml` runs every Sunday 08:30 EAT. It reads the latest STABLE upstream release
(`seaweedfs/seaweedfs` GitHub "latest", never pre-releases). If it is newer than `ARG SEAWEED_REF` in the Dockerfile it
builds the branded image from it. The branding patches assert they matched, so if upstream changed shape the build fails
and nothing is published or committed: `:latest` keeps pointing at the last good image. On success it pushes
`ghcr.io/anandnms2/anands-storage:latest` plus a `:<version>` tag, then commits the new pin to `main`.
Roll back by setting the Coolify image to `ghcr.io/anandnms2/anands-storage:<previous version>`.
Manual run: Actions > upgrade > Run workflow (optionally force a tag).
