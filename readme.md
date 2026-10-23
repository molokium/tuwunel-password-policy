# Install: zxcvbn password policy for tuwunel (nginx + Lua)

Everything runs inside nginx. Nothing in tuwunel's config or database changes.
Rollback = remove two lines and reload.

Assumes: Ubuntu 24.04, distro nginx with `libnginx-mod-http-lua`, tuwunel
listening on `127.0.0.1:8008`, Matrix vhost proxying `/_matrix` to it.

---

## 0. Preflight (read-only)

```bash
# the Lua module must be loaded
nginx -V 2>&1 | tr ' ' '\n' | grep -i lua
ls -l /etc/nginx/modules-enabled/ | grep -i lua

# where is the Matrix vhost and its /_matrix location?
sudo grep -rn "proxy_pass.*8008" /etc/nginx/

# what lua directives already exist?
sudo grep -rn "lua_package_path\|init_by_lua\|access_by_lua\|lua_code_cache" /etc/nginx/

# config include layout
sudo grep -n "include" /etc/nginx/nginx.conf
```

Expected:

- first command prints something like `--with-lua` or the module list shows
  `50-mod-http-lua.conf` → good, stop worrying.
- If there is **no** lua module: `sudo apt install libnginx-mod-http-lua` then
  `ls -l /etc/nginx/modules-enabled/ | grep -i lua` must show
  `50-mod-http-lua.conf` (if it ends in `.removed`, relink it).
- The `proxy_pass.*8008` hit tells you which file holds the block you'll edit
  in step 3. Note it down (`/etc/nginx/sites-enabled/<something>`).

---

## 1. Copy the three files to the server

From the Windows machine (git-bash):

```bash
scp -r /c/Users/win/tuwunel-zxcvbn user@YOUR_SERVER:/tmp/tuwunel-zxcvbn
```

On the server:

```bash
sudo mkdir -p /etc/nginx/lua
sudo install -m 644 -o root -g root \
  /tmp/tuwunel-zxcvbn/zxcvbn-lite.lua \
  /tmp/tuwunel-zxcvbn/zxcvbn-data.lua \
  /tmp/tuwunel-zxcvbn/tuwunel-password-policy.lua \
  /etc/nginx/lua/
ls -l /etc/nginx/lua/
sha256sum /etc/nginx/lua/*.lua
```

Expected sizes: `zxcvbn-lite.lua` ≈ 25 KB, `zxcvbn-data.lua` ≈ 776 KB,
`tuwunel-password-policy.lua` ≈ 8.8 KB. Compare the checksums with:

```
cf2bc9fd9b776dcd18f6ddf6fd6db852a1b2935de31719cdc265b50a1adb3bfb  tuwunel-password-policy.lua
caa3f7b721eb49c8cab0ccb7945d43e39c2a74cb38eb624981cf33cf001abc1d  zxcvbn-lite.lua
fa98631337b5edba5812c44323a4dfc867b37d17a290f2a980b7b833eb2b9cb8  zxcvbn-data.lua
```

---

## 2. Load the wordlist at startup (http context)

Create a dedicated file so the change is isolated and easy to remove:

```bash
sudo tee /etc/nginx/conf.d/00-lua-zxcvbn.conf >/dev/null <<'EOF'
# loads zxcvbn's wordlist once, before workers fork
lua_package_path "/etc/nginx/lua/?.lua;;";

init_by_lua_block {
    require("zxcvbn-lite").init(require("zxcvbn-data"))
}
EOF
```

`/etc/nginx/conf.d/*.conf` is included inside `http{}` on Ubuntu, which is the
only place these two directives are allowed. If your `nginx.conf` does not
include `conf.d/`, put the same two lines inside `http {}` manually.

---

## 3. Attach the policy to /_matrix

Edit the file you found in step 0 (the one with `proxy_pass ... 8008`) and add
**one line** inside the `location /_matrix { ... }` block:

```nginx
location /_matrix {
    access_by_lua_file /etc/nginx/lua/tuwunel-password-policy.lua;
    proxy_pass http://127.0.0.1:8008$request_uri;
    # ... leave everything else exactly as it is ...
}
```

Put it as the first line of the block. Do not create a new `location` — a
`location ^~ /_matrix` elsewhere would take precedence and silently skip the
check.

---

## 4. Test and reload

```bash
sudo nginx -t
```

Expected: `syntax is ok` / `test is successful`. If you see
`unknown directive "init_by_lua_block"`, the Lua module isn't loaded — go back
to step 0.

```bash
sudo systemctl reload nginx
sudo nginx -T | grep -nE "lua_package_path|init_by_lua|access_by_lua"
sudo tail -n 30 /var/log/nginx/error.log
```

The error log should have nothing about `zxcvbn` or `lua`. A startup failure
here means nginx kept the old config (reload is atomic) — check
`sudo systemctl status nginx`.

---

## 5. Verify the behaviour

Weak password → 400 with a reason:

```bash
curl -sS -w '\nHTTP %{http_code}\n' -X POST https://matrix.example.com/_matrix/client/v3/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"pwcheck1","password":"aaaaaaaaaaaaaA","auth":{"type":"m.login.dummy"}}'
```

```json
{"errcode":"M_WEAK_PASSWORD","error":"Password is too easy to guess: it repeats the same characters."}
HTTP 400
```

Keyboard walk:

```bash
curl -sS -X POST https://matrix.example.com/_matrix/client/v3/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"pwcheck1","password":"asdfghjklzxcvB","auth":{"type":"m.login.dummy"}}'
# {"errcode":"M_WEAK_PASSWORD","error":"Password is too easy to guess: it follows a keyboard pattern."}
```

Pass-through proof — a **strong** password with an **existing** localpart, so
nothing is created. You want tuwunel's own answer (`M_USER_IN_USE`), not ours:

```bash
curl -sS -X POST https://matrix.example.com/_matrix/client/v3/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"V7k#mQ2pLw9$Rt","auth":{"type":"m.login.dummy"}}'
# {"errcode":"M_USER_IN_USE","error":"User ID is not available."}
```

If you get `M_USER_IN_USE`, the request reached tuwunel → the Lua check let it
through, as intended.

Then in Element: open the signup form, try a weak password. The red line reads
`MatrixError: [400] Password is too easy to guess: …`. Try a strong one — the
account is created normally.

Watch rejections live:

```bash
sudo tail -f /var/log/nginx/error.log | grep tuwunel-password-policy
```

---

## 6. Tune

`/etc/nginx/lua/tuwunel-password-policy.lua`, first ~20 lines:

```lua
local MIN_LEN                = 14
local MIN_SCORE              = 3      -- 3 = Element's own threshold, 4 = strict
local REQUIRE_PASSWORD       = true
local CHECK_PASSWORD_CHANGES = false  -- true = also police password changes/resets
```

After editing: `sudo nginx -t && sudo systemctl reload nginx`.

`MIN_SCORE = 3` accepts anything Element accepts. `4` rejects more
(`Iloveyou2026!!!`, `Admin@12345678` score 3) but also some reasonable
passwords, and users will see the server error after Element's meter says "ok".

---

## 7. Rollback

One line, no data touched:

```bash
sudo sed -i 's#^\s*access_by_lua_file .*tuwunel-password-policy.*#    # access_by_lua_file disabled#' \
  /etc/nginx/sites-enabled/YOUR_MATRIX_VHOST
sudo nginx -t && sudo systemctl reload nginx
```

Full removal:

```bash
sudo rm /etc/nginx/conf.d/00-lua-zxcvbn.conf
sudo rm /etc/nginx/lua/zxcvbn-lite.lua /etc/nginx/lua/zxcvbn-data.lua \
        /etc/nginx/lua/tuwunel-password-policy.lua
sudo nginx -t && sudo systemctl reload nginx
```

(Remove the `access_by_lua_file` line from the vhost first, otherwise the
reload fails with "failed to load external Lua file".)

---

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `nginx -t` fails: `unknown directive "init_by_lua_block"` | libnginx-mod-http-lua not loaded | `apt install libnginx-mod-http-lua`, check `modules-enabled/` |
| `nginx -t` fails: `failed to load external Lua file` | `access_by_lua_file` pointed at a missing file | check the path, `chmod 644` |
| 500 on every register, log says `zxcvbn-lite is not initialised` | `init_by_lua_block` missing (or in a `server{}` block) | it must be in `http{}` |
| every password accepted | wordlist not loaded (`maxlen == 0` would have failed at startup, so this means the policy file isn't attached) | `sudo nginx -T \| grep access_by_lua` |
| `module 'zxcvbn-lite' not found` | `lua_package_path` missing | add `/etc/nginx/lua/?.lua;;` |
| JSON body read fails | `client_body_buffer_size` tiny | bodies are a few hundred bytes; the script also handles nginx's spooled temp file |
