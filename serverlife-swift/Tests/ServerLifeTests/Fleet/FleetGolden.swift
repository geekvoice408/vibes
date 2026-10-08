// Generated from the Electron app with js-yaml 5.4.2 (see FleetFormatsTests).
// Do not edit by hand.

enum FleetGolden {
    static let dump100: [String] = [
##"""
a: plain
b: 'yes'
c: '123'
d: 'a: b'
e: '#x'
f: '- x'
g: ''
h: 'ends '
i: "tab\there"
j: naïve ☃
k: it's
l: say "hi"
m: 'null'
'n': '~'
o: '0x1F'
p: '1.5'
q: '.inf'
r: '2024-01-02'
s: 'on'
t: 'True'
u: '@home'
v: '%x'
w: '`x'
x: '!x'
'y': '&x'
z: '*x'
aa: '|x'
ab: '>x'
ac: ?x
ad: x?
ae: 'a #b'
af: a#b
ag: '{x}'
ah: '[x]'
ai: x,y
aj: ' lead'
ak: '-'
al: --- x
am: '1_000'
an: '0o17'
ao: '1e3'
ap: '10:20'
aq: '<<'
ar: 'Y'
as: 'x:'
at: :x
au: é
av: a\b
aw: "\x01"
ax: π=3
ay: '='
az: web-1.example.com
ba: ubuntu@host

"""##,
##"""
n1: 10
n2: 120
n3: 1.5
n4: true
n5: false
n6: -3
n7: 0

"""##,
##"""
multi: |
  line one
  line two
nochomp: |-
  a
  b
keep: |+
  a
  b

lead: |2
    indented
  next
onlynl: "\n"
empty: ''
long: >-
  word word word word word word word word word word word word word word word word word word word
  word word word word word word word word word word word
longml: >
  xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx
  xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx 

  short
longnosp: yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
spacey: a  b
trailnl: |
  abc
tabs: "a\tb\nc\n"
crlf: "a\r\nb\n"
unicodeml: |
  héllo
  wörld

"""##,
##"""
list:
  - type: teleport
    name: n1
    cluster: c
  - type: ssh
    alias: ent
nested:
  a:
    b: c
emptyl: []
emptym: {}
scal:
  - a
  - b

"""##
    ]
    static let dump120: [String] = [
##"""
a: plain
b: 'yes'
c: '123'
d: 'a: b'
e: '#x'
f: '- x'
g: ''
h: 'ends '
i: "tab\there"
j: naïve ☃
k: it's
l: say "hi"
m: 'null'
'n': '~'
o: '0x1F'
p: '1.5'
q: '.inf'
r: '2024-01-02'
s: 'on'
t: 'True'
u: '@home'
v: '%x'
w: '`x'
x: '!x'
'y': '&x'
z: '*x'
aa: '|x'
ab: '>x'
ac: ?x
ad: x?
ae: 'a #b'
af: a#b
ag: '{x}'
ah: '[x]'
ai: x,y
aj: ' lead'
ak: '-'
al: --- x
am: '1_000'
an: '0o17'
ao: '1e3'
ap: '10:20'
aq: '<<'
ar: 'Y'
as: 'x:'
at: :x
au: é
av: a\b
aw: "\x01"
ax: π=3
ay: '='
az: web-1.example.com
ba: ubuntu@host

"""##,
##"""
n1: 10
n2: 120
n3: 1.5
n4: true
n5: false
n6: -3
n7: 0

"""##,
##"""
multi: |
  line one
  line two
nochomp: |-
  a
  b
keep: |+
  a
  b

lead: |2
    indented
  next
onlynl: "\n"
empty: ''
long: >-
  word word word word word word word word word word word word word word word word word word word word word word word
  word word word word word word word
longml: >
  xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx
  xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx xxxxxxxxxxxxxxxxxxxx 

  short
longnosp: yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
spacey: a  b
trailnl: |
  abc
tabs: "a\tb\nc\n"
crlf: "a\r\nb\n"
unicodeml: |
  héllo
  wörld

"""##,
##"""
list:
  - type: teleport
    name: n1
    cluster: c
  - type: ssh
    alias: ent
nested:
  a:
    b: c
emptyl: []
emptym: {}
scal:
  - a
  - b

"""##
    ]
    static let basic = ##"""
# ServerLife multi-exec run
# Re-open with: Multi-Exec panel -> Load YAML
version: 1
kind: serverlife.multiexec
name: df -h /
created: '2026-10-07T12:34:56.789Z'
command: |
  df -h /
  uptime
options:
  concurrency: 10
  timeoutSeconds: 120
  stopOnError: false
targets:
  - type: teleport
    name: node-1
    cluster: example.teleport.sh
    proxy: example.teleport.sh:443
    login: ubuntu
  - type: ssh
    alias: ent
    user: root
    port: 2222
  - type: ssh
    alias: web
    user: deploy

"""##
    static let selector = ##"""
# ServerLife multi-exec run
# Re-open with: Multi-Exec panel -> Load YAML
#
# This run selects its hosts by tag, so it runs against whatever matches
# at the time. The targets below are a snapshot of what matched when it
# was saved, and are not what will be used.
version: 1
kind: serverlife.multiexec
name: 'yes'
description: 'Check: all things'
created: '2026-10-07T12:34:56.789Z'
command: >
  systemctl restart nginx && sleep 2 && systemctl status nginx --no-pager --lines=50 | grep -v
  something-very-long-here-to-fold
options:
  concurrency: 5
  timeoutSeconds: 31
  stopOnError: true
selector:
  cluster: prod
  query: env=prod role:web
targets:
  - type: teleport
    name: n2
    cluster: prod

"""##
    static let results = ##"""
# ServerLife multi-exec results
version: 1
kind: serverlife.multiexec.results
command: |
  uname -a
startedAt: '2026-01-02T03:04:05.006Z'
endedAt: '2026-01-02T03:04:09.000Z'
summary:
  total: 4
  succeeded: 1
  failed: 2
results:
  - host: web-1
    status: done
    exitCode: 0
    durationMs: 412
    stdout: |
      Linux web-1 6.1.0
  - host: db (ubuntu)
    status: error
    exitCode: 255
    durationMs: 1200
    stderr: |
      ssh: connect to host db port 22: Connection refused
  - host: x
    status: timeout
    stdout: "tab\there\n"
  - host: 'y'
    status: cancelled

"""##
}
