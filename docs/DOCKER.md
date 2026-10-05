# Dedicated server with Docker

The [dedicated server](SERVER.md) also comes as a container image, for Linux machines (x86-64
and ARM64) and for Docker Desktop on Windows and macOS:

```
ghcr.io/gtaepic/openomsi-server:latest
```

It holds the server of the latest openOMSI release (a new image follows every release, usually
within a few hours) and nothing of the game: **the server needs your own OMSI 2**, mounted read-only,
exactly as the game does. Everything the server keeps - `server.cfg`, its icon, mods, the
game's own data - lives in one folder of yours, mounted at `/data`.

## Quick start

With Docker Compose: put [`docker/compose.yaml`](../docker/compose.yaml) and
[`docker/.env.example`](../docker/.env.example) (renamed `.env`) into a folder of their own,
set `OMSI2_PATH` in `.env` to your OMSI 2 folder (the one with `Omsi.exe`, `maps` and
`Vehicles` in it), and:

```sh
mkdir data && sudo chown 1000:1000 data     # Linux: the server runs as user 1000
docker compose up -d
docker compose logs -f                      # watch it load its map
```

Or with `docker run`:

```sh
docker run -d --name openomsi --restart unless-stopped \
  --mount type=bind,src="/path/to/OMSI 2",dst=/omsi2,readonly \
  -v "$PWD/data:/data" \
  -p 27015:27015/udp -p 27015:27015/tcp -p 27025:27025 \
  ghcr.io/gtaepic/openomsi-server:latest
```

The first start writes `data/server.cfg` with every setting and what it does (the map, the
time, traffic, players, the tunnel, ...). With the default `tunnel = 1` the log soon shows
`Server address for the players: https://….trycloudflare.com`: that address works from
anywhere, through any router. Players add it - or this machine's address, e.g. `1.2.3.4` - in
openOMSI → **Multiplayer → Servers**.

## OMSI 2 on the server

The server reads the original game's files like the game does (it never writes to them), and
every player needs the same base. A complete OMSI 2 folder (any version, Steam or retail) works;
it must at least have `Omsi.exe`, `envir.cfg`, `maps/Grundorf`, `maps/Berlin-Spandau`,
`Vehicles/MAN_SD200`, `MAN_SD202`, `MAN_NL_NG`, `Sceneryobjects`, `Splines`, `Texture`, `Fonts`,
`Humans`, `Weather` and `Inputs`. Mounting the folder above it works as well when it holds a
folder named `OMSI 2`.

To get it onto a Linux server, copy your installation there (`rsync`, `scp`, a USB disk), or let
SteamCMD download your copy straight into a Docker volume - with your own Steam account, which
must own OMSI 2 (it asks for the Steam Guard code):

```sh
docker run -it --rm -v omsi2:/omsi2 steamcmd/steamcmd:latest \
  +@sSteamCmdForcePlatformType windows +force_install_dir /omsi2 \
  +login <your Steam name> +app_update 252530 validate +quit
```

and mount that volume instead of a folder: `--mount type=volume,src=omsi2,dst=/omsi2,readonly`
(in `compose.yaml`: the `/omsi2` mount `type: volume` with `source: omsi2`, and `omsi2` under
the file's `volumes:` with `external: true`).

## The server's folder

| In `/data` | What it is |
| --- | --- |
| `server.cfg` | the settings ([SERVER.md](SERVER.md) explains them); written with the defaults on the first start, then only you change it |
| `server-icon.png` | the server's icon in the players' list (64x64 PNG), optional |
| `content/` | mods, laid out like the OMSI 2 folder (see below) |
| `.openomsi/` | the game's own data: `settings.cfg` (passenger and fare settings the server follows), the downloaded cloudflared, status files |

Save `server.cfg` as UTF-8 (a server stops with exit code 2 on a file in another encoding).

## Settings from the environment

Every `server.cfg` key can also be given as a variable `OMSI_SERVER_<KEY>` - in capitals,
`max_players` as `OMSI_SERVER_MAX_PLAYERS` - which wins over the file:

```yaml
    environment:
      OMSI_SERVER_NAME: My openOMSI server
      OMSI_SERVER_MAP: maps/Grundorf/global.cfg
      OMSI_SERVER_ADMIN_PASSWORD_FILE: /run/secrets/openomsi_admin
```

`OMSI_SERVER_<KEY>_FILE` reads the value from a file (a Docker secret, for the passwords). The
server gets `server.cfg` and these lines together; the file itself is not changed. A `$` in a
compose file is written `$$`. `docker exec openomsi docker-entrypoint.sh print-config` shows
what the server gets (passwords hidden), and the log says at the start which ports it takes.

Other variables the image sets or understands:

| Variable | Default | What it does |
| --- | --- | --- |
| `TZ` | `Etc/UTC` | the time zone; the server's clock follows it with `real_time = 1` (e.g. `Europe/Berlin`) |
| `OMSI_LAN_IP` | - | the address put first into session codes (this machine's LAN address; see below) |
| `OMSI_NO_TUNNEL` / `OMSI_NO_BRIDGE` | - | `1`: no Cloudflare tunnel / none of tunnel, STUN, UPnP and the code relay |
| `OMSI_NO_LAN_MODS` | - | `1`: the server hands out no mods |
| `RUST_LOG` | `info` | how much the log says (`warn`, `debug`, ...) |
| `OMSI_ROOT`, `OMSI_CONTENT`, `HOME` | `/omsi2`, `/data/content`, `/data` | where OMSI 2, the mods and the game's data are; leave them |

## Ports and the network

| Port | What for |
| --- | --- |
| `27015/udp` | the game, for players who join by address (`host` or `host:27015`) |
| `27015/tcp` | the server's mods, fetched by those players before they load the map |
| `27025/tcp` | the web port: `/status` for the players' server list, players joining over WebSockets (the launcher's default for a listed server) and their mods |

Other ports are set with `port` and `web_port`; keep the web port at the game port + 10 (27016
and 27026, ...), where the launcher looks for it when a player gives only `host:port`, and
publish the same numbers outside as inside (`-p 27016:27016/udp ...`).

* **The tunnel** (`tunnel = 1`, the default) needs nothing open: the server fetches
  cloudflared (once, into `data/.openomsi/bin`) and the log prints the `https://….trycloudflare.com`
  address. It changes with every restart. With ports open to the internet, `tunnel = 0`.
* **Players on the same network** add `192.168.x.y` (the Docker host's address). Finding a
  server by itself on the LAN (`--lan-join auto`), UPnP port forwarding on the router and LAN
  addresses in session codes need the host's network: `network_mode: host` in compose (Linux),
  without `ports:`. In Docker's usual network the session code carries the container's own
  address instead; `OMSI_LAN_IP` puts the right one first.
* The server listens on IPv4 only.

## Mods

`data/content` is the server's content folder: it is laid out like the OMSI 2 folder
(`Vehicles`, `maps`, `Sceneryobjects`, `Splines`, ...) and searched before it, as the game's
own content folder is ([USER_GUIDE.md](USER_GUIDE.md), *Mods and the content folder*). A mod
goes there in three ways:

* its folders copied into `data/content` as they would go into OMSI 2;
* a `.zip` laid out like OMSI 2, put into `data/content/Archives/` (read in place);
* any archive or folder through the launcher's installer, which sorts it into place:
  `docker exec openomsi openomsi-launcher --cli install '{"path":"/data/incoming/mod.7z"}'`
  (with the archive in `data/incoming`; `--cli mods` lists what is installed).

Restart the server afterwards. Players who lack a mod the server's map or buses use get it from
the server when they join. Mods installed into the OMSI 2 folder itself count as the base game
and are not handed out.

## Administration

The server takes admin commands only from its own machine, so they are given inside the
container (set `admin_password` first):

```sh
docker exec openomsi omsi-admin "say The server restarts in five minutes"
docker exec openomsi omsi-admin "weather set Weather/#CAVOK.owt" "clock 30600"
docker exec openomsi omsi-status          # name, map, players, time, weather, version
```

With Docker Compose it is `docker compose exec server omsi-admin "..."`. The commands are those
of the game's Administration menu (`say`, `kick <id>`, `clock <seconds>`, `weather next`, ...).
Players who say `/admin <password>` in the chat get the same menu in the game.

## Updating

Players' games update themselves to every new release. The server and the players must speak
the same network protocol (a game of another one is turned away when joining), and newer games
may bring things an older server does not pass on - so keep the server current:

```sh
docker compose pull && docker compose up -d
```

(or a tool that does it on a schedule). `:latest` is the newest release; every release also has
its own tag (`:0.1.1541`) to stay on one.

## Several maps

A server plays one map. For more, run a server per map - all from the same read-only OMSI 2
folder - and put them under one web address with a reverse proxy:
[`docker/compose.multi.yaml`](../docker/compose.multi.yaml) does it with Caddy (and HTTPS):

```
https://omsi.example.com/spandau     the Berlin-Spandau server
https://omsi.example.com/grundorf    the Grundorf server
```

Each is added in **Multiplayer → Servers** by that address and shows its map and players there.
The proxy must

* **take the path's first part off** (`/spandau/status` → `/status`): a server answers
  `/status`, `/icon.png`, `/ws` (players) and `/tcp` (mods) at its root - Caddy's
  `handle_path`, nginx's `location /spandau/ { proxy_pass http://spandau:27025/; }` with the
  WebSocket upgrade headers;
* pass WebSockets on, and leave them open (the game pings every 20 seconds);
* never pass `/admin` on (the servers refuse it from a proxy anyway).

A name per server (`spandau.example.com`) works the same, without the path. Each server keeps
its whole map in memory - Berlin-Spandau about 1.2 GB, Grundorf about 0.3 GB, a big add-on map
more; `docker stats` shows them.

## Health, logs and stopping

* `docker ps` shows the server *healthy* once its map is in and the world turns, *starting*
  while it loads (minutes on a big map or a slow disk), *unhealthy* when its web port does not
  answer where `server.cfg` says or its main loop has stopped.
* `docker logs` is the server's log; the line `server: running` says it is ready.
* `docker stop` ends the session at once: the players are told the host left (their games look
  for it again) and the router's port forward, if any, is taken back. A server stopped while it
  is still loading ends with exit code 143.
* Exit code 1: no OMSI 2 at `/omsi2` (the log says which files are missing); 2: `server.cfg`
  could not be read.

## Docker Desktop on Windows and macOS

The image runs there as on Linux; the game and the server can even run on the same PC (add
`localhost:27025`). Mounting a folder of the Windows disk is slow for the many small files of
OMSI 2, so the map loads for a long time (Berlin-Spandau about 4½ minutes, Grundorf half a
minute): a copy in a Docker volume (or inside WSL) is much faster. Give Docker's VM enough
memory for the map (Settings → Resources, or `.wslconfig`). A path with spaces is given whole:

```
--mount type=bind,src="E:\SteamLibrary\steamapps\common\OMSI 2",dst=/omsi2,readonly
```

(in `.env`: `OMSI2_PATH=E:/SteamLibrary/steamapps/common/OMSI 2`). Players on the LAN add the
PC's address; finding the server by itself needs host networking (above), which Docker Desktop
only has as an option in its settings.

## Building the image

`ghcr.io/gtaepic/openomsi-server` is built from each release's Linux server download by
`.github/workflows/docker.yml`. To build an image yourself from a checkout:

```sh
docker build -t openomsi-server .                         # compiles this checkout
docker build --build-arg BINARY=release --build-arg OPENOMSI_VERSION=0.1.1541 -t openomsi-server .
```

The first compiles the server for the machine's own architecture (`--build-arg
CARGO_BUILD_JOBS=2` when Docker's VM runs out of memory). It takes a while - about a quarter of
an hour on a 12-thread PC - and for its last several minutes, while the program is linked and
optimised as a whole, it prints nothing: that is not a hang. The second takes that release's
download from GitHub for any architecture (`--platform linux/arm64`) in a minute or two.
