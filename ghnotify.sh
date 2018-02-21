#!/bin/bash

#
# Shell script to parse github.com using only the GitHub API for a
# configurable selection of repositories and branches, emailing a
# summary of new commits.
#
# No email is sent when there have been no new commits.
#
# Requires: qprint (apt-get install qprint).
#
# Reads a list of repositories to be monitored from ./ghnotify.conf:
#
#   <owner/repository/branch> <name of monitored repository>
#
# Example:.
#
#   raspberrypi/firmware/master     Raspberry Pi Firmware
#
# Writes the latest SHA of each monitored repository to ./ghnotify.commits.
# Writes the latest PR number of each monitored repository to ./ghnotify.pulls.
#
# Uses HTML template fragment files ./ghnotify.template.main and
# ./ghnotify.template.sub to generate the HTML message, which is then
# converted to quoted-printable format using the qprint utility.
#
# To authenticate with github.com, create a file named ~/.git.conf.
# Specify the username and password used for GitHub access to avoid GitHub
# rate limits. Authentication is optional, and may be unecessary depending on
# often you query GitHub, and how many repositories are being monitored. See
# GitHub API for details on rate limiting: https://developer.github.com/v3/rate_limit
#
# Also specify your email address in ~/.git.conf:
#
#   GIT_USERNAME="username"
#   GIT_PASSWORD="password"
#   EMAILTO="email@address.com"
#
# You can also use ~/.git.conf to override other variables, such as which email binary
# to use when sending email (the script will attempt find a suitable MTA).
#
# (c) Neil MacLeod 2014-present :: ghnotify@nmacleod.com :: https://github.com/MilhouseVH/ghnotify
#
VERSION="v0.2.3"

BIN=$(readlink -f $(dirname $0))

# Avoid running more than one instance
PIDFILE="/tmp/$(basename $0).pid"
[ -f "${PIDFILE}" ] && exit 1

GHNOTIFY_CONF=ghnotify.conf
GHNOTIFY_DATA=ghnotify.dat
GHNOTIFY_CDATA=ghnotify.commits
GHNOTIFY_PDATA=ghnotify.pulls
GHNOTIFY_RDATA=ghnotify.releases
[ -z "${GHNOTIFY_GITDIR}" ] && GHNOTIFY_GITDIR=git

GHNOTIFY_WORKDIR=$(mktemp -d)
GHNOTIFY_CTEMP=${GHNOTIFY_WORKDIR}/.ctemp
GHNOTIFY_PTEMP=${GHNOTIFY_WORKDIR}/.ptemp
GHNOTIFY_RTEMP=${GHNOTIFY_WORKDIR}/.rtemp
GHNOTIFY_LOCKDIR=${GHNOTIFY_WORKDIR}/.locks
TMPFILE=${GHNOTIFY_WORKDIR}/.tmpfile

WEBWORKFILE=${GHNOTIFY_WORKDIR}/init.webrequest

USEPYTHON=${USEPYTHON:-python}

trap 'rm -rf -- "${PIDFILE}" "${GHNOTIFY_WORKDIR}"' EXIT

echo $$ > $PIDFILE

DEFAULTMAXJOBS=$(($(nproc) * 10))
MAXJOBS=${MAXJOBS:-${DEFAULTMAXJOBS}}

# Stop sending emails if the specified number of days have elapsed since
# the last modification to the CHECK_FILE.
CHECK_INTERVAL_DAYS=14
CHECK_FILE=${BIN}/patches.dat

PY_COMMIT_PR='
import os, sys, json, datetime, codecs, re, io

if sys.version_info >= (3, 0):
  import urllib.request as urllib2
else:
  import urllib2

DEBUGGING=os.environ.get("DEBUG")
DEFAULT_AVATAR="https://assets-cdn.github.com/images/gravatars/gravatar-user-420.png"
NOW_DATE=datetime.datetime.utcnow()
NOW_YEAR=NOW_DATE.strftime("%Y")

if sys.version_info >= (3, 1):
  sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())
  sys.stderr = codecs.getwriter("utf-8")(sys.stderr.detach())
else:
  sys.stdout = codecs.getwriter("utf-8")(sys.stdout)
  sys.stderr = codecs.getwriter("utf-8")(sys.stderr)

def debug(msg):
  if DEBUGGING:
    sys.stdout.write("%s\n" % msg)

def whendelta(when):
  when_date = datetime.datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ")
  when_year = when[:4]
  delta = NOW_DATE - when_date

  debug("UTC Now: %s, When: %s, Delta: %s" % (NOW_DATE, when_date, delta))

  if delta.days > 30:
    if NOW_YEAR != when_year:
      return "on %s" % when_date.strftime("%d %b %Y")
    else:
      return "on %s" % when_date.strftime("%d %b")

  if delta.days > 0:
    return "%s day%s ago" % (delta.days, "s"[delta.days==1:])

  if delta.seconds >= 3600:
    hours = int(round(float(delta.seconds) / 3600))
    if hours > 0:
      if hours == 1:
        return "an hour ago"
      else:
        return "%s hours ago" % (hours)
  else:
    mins = int(round(float(delta.seconds) / 60))
    return "%s minute%s ago" % (mins, "s"[mins==1:])

def setavatar(list, creator):
  id = creator.get("login", creator.get("name", ""))
  if id and id not in list:
    url = creator.get("avatar_url", DEFAULT_AVATAR)
    url = url[:-1] if url[-1:] == "?" else url
    list[id] = {"avatar": url, "gravatar": creator.get("gravatar_id", None) }
  return

def getavatar(list, creator, size=20, enable_gravatar=False):
  id = creator.get("login", creator.get("name", ""))
  if id and id in list:
    avatar = list[id]["avatar"]
    gravatar = list[id]["gravatar"]
    if gravatar and enable_gravatar:
      return "https://1.gravatar.com/avatar/%s?d=%s&r=x&s=%d" % (gravatar, urllib2.quote(avatar, "()"), size)
    else:
      return "%s?s=%d" % (avatar, size)
  else:
    return "%s?s=%d" % (DEFAULT_AVATAR, size)

def htmlsafe(input):
  if input:
    tmp = input.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
  else:
    tmp = input
  return toUnicode(tmp)

def toUnicode(data):
  if sys.version_info >= (3, 0): return data

  if isinstance(data, basestring):
    if not isinstance(data, unicode):
      try:
        data = unicode(data, encoding="utf-8", errors="ignore")
      except UnicodeDecodeError:
        pass

  return data

data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))

dfile = sys.argv[1]
ditem = sys.argv[2]
dtype = sys.argv[3]

output = codecs.open(dfile, "w", encoding="utf-8")

if "message" in jdata:
  output.write(u"ERROR\n")
  output.close()
  sys.exit(0)

if dtype == "commits" and "commits" in jdata:
  debug("%d commits loaded for %s" % (len(jdata["commits"]), jdata["url"]))
  try:
    PULL_URL = re.sub("compare/[a-z0-9]*...[a-z0-9]*$", "pull/", jdata["html_url"])
    RE_PULL  = re.compile("#([0-9]+)")

    avatars = {}
    for c in jdata["commits"]:
      if c["author"]: setavatar(avatars, c["author"])
      if c["committer"]: setavatar(avatars, c["committer"])

    for c in reversed(jdata["commits"]):
      if c["author"]:
        avatar_url = getavatar(avatars, c["author"])
        author = c["author"]["login"]
      else:
        avatar_url = getavatar(avatars, c["commit"]["author"])
        author = c["commit"]["author"]["name"]

      commitdata = "%s authored %s" % (author, whendelta(c["commit"]["author"]["date"]))

      if c["commit"]["committer"] and c["commit"]["author"]:
         if c["commit"]["committer"]["name"] != c["commit"]["author"]["name"] or \
            c["commit"]["committer"]["email"] != c["commit"]["author"]["email"]:
           commitdata = "%s (%s committed %s)" % (commitdata, c["commit"]["committer"]["name"], whendelta(c["commit"]["committer"]["date"]))

      message = htmlsafe(c["commit"]["message"].split("\n")[0])
      message = RE_PULL.sub("<a href=\"%s\\1\">#\\1</a>" % PULL_URL, message)

      output.write(u"%s %s %s\n" % (avatar_url, htmlsafe(commitdata.replace(" ", "\001")), message))

      debug("  Message : %s" % message)
      debug("  Avatar  : %s" % avatar_url)
      debug("  Who/When: %s" % commitdata)
  except:
    raise
    sys.exit(1)

elif dtype == "pulls":
  debug("%d pull requests loaded" % len(jdata))
  try:
    avatars = {}
    for c in jdata:
      if c["user"]: setavatar(avatars, c["user"])

    lastpr = 0
    if len(sys.argv) == 5:
      tmp = sys.argv[4]
      lastpr = int(tmp) if tmp and tmp != "unknown" else 0

    if len(jdata) != 0:
      output.write(u"%s\n" % jdata[0]["number"])

    for pr in [x for x in jdata if x["number"] > lastpr]:
      avatar_url = getavatar(avatars, pr["user"])
      author = pr["user"]["login"]
      pulldata = "%s authored %s" % (author, whendelta(pr["created_at"]))
      message = "<a href=\"%s\">#%s</a> %s" % (pr["html_url"], pr["number"], htmlsafe(pr["title"]))

      output.write(u"%s %s %s\n" % (avatar_url, htmlsafe(pulldata.replace(" ", "\001")), message))

      debug("  Message : %s" % message)
      debug("  Avatar  : %s" % avatar_url)
      debug("  Who/When: %s" % pulldata)
  except:
    raise

output.close()
'

PY_COMMIT_GIT='
import os, sys, json, datetime, codecs, re, io

if sys.version_info >= (3, 0):
  import urllib.request as urllib2
else:
  import urllib2

DEBUGGING=os.environ.get("DEBUG")
DEFAULT_AVATAR="https://assets-cdn.github.com/images/gravatars/gravatar-user-420.png"
NOW_DATE=datetime.datetime.utcnow()
NOW_YEAR=NOW_DATE.strftime("%Y")

if sys.version_info >= (3, 1):
  sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())
  sys.stderr = codecs.getwriter("utf-8")(sys.stderr.detach())
else:
  sys.stdout = codecs.getwriter("utf-8")(sys.stdout)
  sys.stderr = codecs.getwriter("utf-8")(sys.stderr)

def debug(msg):
  if DEBUGGING:
    sys.stdout.write("%s\n" % msg)

def whendelta(when):
  when_date = datetime.datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ")
  when_year = when[:4]
  delta = NOW_DATE - when_date

  debug("UTC Now: %s, When: %s, Delta: %s" % (NOW_DATE, when_date, delta))

  if delta.days > 30:
    if NOW_YEAR != when_year:
      return "on %s" % when_date.strftime("%d %b %Y")
    else:
      return "on %s" % when_date.strftime("%d %b")

  if delta.days > 0:
    return "%s day%s ago" % (delta.days, "s"[delta.days==1:])

  if delta.seconds >= 3600:
    hours = int(round(float(delta.seconds) / 3600))
    if hours > 0:
      if hours == 1:
        return "an hour ago"
      else:
        return "%s hours ago" % (hours)
  else:
    mins = int(round(float(delta.seconds) / 60))
    return "%s minute%s ago" % (mins, "s"[mins==1:])

def getavatar(size=20):
  return "%s?s=%d" % (DEFAULT_AVATAR, size)

def htmlsafe(input):
  if input:
    tmp = input.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
  else:
    tmp = input
  return toUnicode(tmp)

def toUnicode(data):
  if sys.version_info >= (3, 0): return data

  if isinstance(data, basestring):
    if not isinstance(data, unicode):
      try:
        data = unicode(data, encoding="utf-8", errors="ignore")
      except UnicodeDecodeError:
        pass

  return data

def epoch2date(epoch):
  return datetime.datetime.fromtimestamp(int(epoch.split(" ")[0])).strftime("%Y-%m-%dT%H:%M:%SZ")

dfile = sys.argv[1]
ditem = sys.argv[2]

output = codecs.open(dfile, "w", encoding="utf-8")

jdata={"commits": []}

for line in sys.stdin:
  fields = line.split("\t")
  jdata["commits"].append({
                           "author":    {"name": fields[0], "date": epoch2date(fields[1]), "email": fields[2]},
                           "committer": {"name": fields[3], "date": epoch2date(fields[4]), "email": fields[5]},
                           "message": fields[6]
                           })

debug("%d commits loaded" % len(jdata["commits"]))
try:
  for c in jdata["commits"]:
    avatar_url = getavatar()
    author = c["author"]["name"] if c["author"]["name"] else c["committer"]["name"]

    commitdata = "%s authored %s" % (author, whendelta(c["author"]["date"]))

    if c["committer"]["name"] and c["author"]["name"]:
       if c["committer"]["name"] != c["author"]["name"] or \
          c["committer"]["email"] != c["author"]["email"]:
         commitdata = "%s (%s committed %s)" % (commitdata, c["committer"]["name"], whendelta(c["committer"]["date"]))

    message = htmlsafe(c["message"].split("\n")[0])

    output.write(u"%s %s %s\n" % (avatar_url, htmlsafe(commitdata.replace(" ", "\001")), message))

    debug("  Message : %s" % message)
    debug("  Avatar  : %s" % avatar_url)
    debug("  Who/When: %s" % commitdata)
except:
  raise
  sys.exit(1)

output.close()
'

PY_JSON_DATA='
import sys, json, datetime
data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))

variable = sys.argv[1]

tdata = jdata
for v in variable.split("."):
  if v in tdata:
    tdata = tdata[v]
print(tdata)
'

warn() {
  local fmt="$1"
  shift
  printf "ghnotify.sh: $fmt\n" "$@" >&2
}

die() {
  local st="$?"
  if [[ "$1" != *[^0-9]* ]]; then
    st="$1"
    shift
  fi
  warn "$@ - terminating"
  exit "$st"
}

logger() {
  local item=$1
  while IFS= read -r line; do
    printf "[%s] %s\n" ${item} "${line}"
  done
}

getcomponent()
{
  local field="$1" string="$2" remove="$3"
  if [ -n "${remove}" ]; then
    echo "${string}" | cut -d/ -f${field} | sed "s/${remove}//"
  else
    echo "${string}" | cut -d/ -f${field}
  fi
}

getlatestsha()
{
  local item="$1" output="$2" owner_repo_branch="$3" gitrepodir="$4"
  local URL

  if [ -n "${gitrepodir}" ]; then
    git --git-dir="${gitrepodir}/.git" rev-parse HEAD > "${output}" && return 0 || return 1
  fi

  URL="${GITAPI}/$(getcomponent 1 "${owner_repo_branch}")/$(getcomponent 2 "${owner_repo_branch}")/commits?per_page=1&sha=$(getcomponent 3- "${owner_repo_branch}")"
  webrequest "${URL}" || return 1

  cat ${WEBWORKFILE} | ${USEPYTHON} -c '
import sys, json
data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))
for item in jdata:
  if "sha" in item:
    print("%s" % item["sha"])
  break
' > "${output}"

  return 0
}

getalltags()
{
  local item="$1" output="$2" owner_repo_branch="$3" gitrepodir="$4"
  local URL

  if [ -n "${gitrepodir}" ]; then
    (
      cd ${gitrepodir}
      echo "['$(git describe --tags $(git rev-list --tags --max-count=1 2>/dev/null) 2>/dev/null)']" > "${output}"
    ) && return 0 || return 1
  fi

  URL="${GITAPI}/$(getcomponent 1 "${owner_repo_branch}")/$(getcomponent 2 "${owner_repo_branch}")/tags"
  webrequest "${URL}" Y || return 1

  cat ${WEBWORKFILE} | ${USEPYTHON} -c '
import sys, json
data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))
tags = []
for page in jdata:
  for item in page:
    tags.append(item["name"])
print(json.dumps(sorted(tags)))
'> "${output}"

  return 0
}

getnewtagdetails()
{
  local item="$1" output="$2" owner_repo_branch="$3" gitrepodir="$4" lastvalue="$5" crntvalue="$6"

  ${USEPYTHON} -c '
from __future__ import print_function
import sys, json
DEFAULT_AVATAR="https://assets-cdn.github.com/images/gravatars/gravatar-user-420.png"
last=json.loads(sys.argv[1].replace(chr(39),"\""))
crnt=json.loads(sys.argv[2].replace(chr(39),"\""))
for tag in crnt:
  if tag and tag not in last:
    print("%s %s" % (DEFAULT_AVATAR, tag))
' "${lastvalue}" "${crntvalue}" > "${output}"
}

getcommitdetails()
{
  local item="$1" output="$2" owner_repo_branch="$3" gitrepodir="$4" lastvalue="$5" crntvalue="$6"
  local URL

  if [ -n "${gitrepodir}" ]; then
    [ "${lastvalue}" == "0" ] && lastvalue="${crntvalue}"
    git --git-dir="${gitrepodir}/.git" \
      log ${lastvalue}...${crntvalue} \
      --date="raw" \
      --pretty="tformat:%an%x09%ad%x09%ae%x09%cn%x09%cd%x09%ce%x09%s" | \
      ${USEPYTHON} -c "${PY_COMMIT_GIT}" "${output}" "${item}"
  else
    URL="${GITAPI}/$(getcomponent 1 "${owner_repo_branch}")/$(getcomponent 2 "${owner_repo_branch}")/compare/${lastvalue}...${crntvalue}"
    webrequest "${URL}" || return 1
    [ "${DEBUG}" == "Y" ] && cat ${WEBWORKFILE} >${BIN}/dbg_commits_$(echo "${owner_repo_branch}"|sed "s#/#_#g")
    cat ${WEBWORKFILE} | ${USEPYTHON} -c "${PY_COMMIT_PR}" "${output}" "${item}" commits
  fi

  return $?
}

getpulldetails()
{
  local item="$1" output="$2" owner_repo_branch="$3" lastvalue="$4"
  local URL

  URL="${GITAPI}/$(getcomponent 1 "${owner_repo_branch}")/$(getcomponent 2 "${owner_repo_branch}")/pulls"
  webrequest "${URL}" || return 1
  [ "${DEBUG}" == "Y" ] && cat ${WEBWORKFILE} >${BIN}/dbg_pulls_$(echo "${owner_repo_branch}"|sed "s#/#_#g")
  cat ${WEBWORKFILE} | ${USEPYTHON} -c "${PY_COMMIT_PR}" "${output}" "${item}" pulls "${lastvalue}"
  return $?
}

getcommitsurl()
{
  local url="$1" branch=

  if [[ ${url} =~ ^git@github.com: ]]; then
    url="${url/git@github.com:/}"
    echo "https://github.com/$(getcomponent 1 "${url}")/$(getcomponent 2 "${url}" "\.git$")/commits/$(getcomponent 3 "${url}")"
  elif [[ ${url} =~ ^git:// ]]; then
    if [[ ${url} =~ ^git://github.com ]]; then
      url="${url/git:\/\/github.com\//}"
      echo "https://github.com/$(getcomponent 1 "${url}")/$(getcomponent 2 "${url}" "\.git$")/commits/$(getcomponent 3 "${url}")"
    else
      branch="${url##*/}"
      url=${url%/*}
      if [ -n "${branch}" ]; then
        echo "${url/git:/https:}/log/?h=${branch}"
      else
        echo "${url/git:/https:}/log"
      fi
    fi
  else
    echo "https://github.com/$(getcomponent 1 "${url}")/$(getcomponent 2 "${url}")/commits/$(getcomponent 3 "${url}")"
  fi
}

getpullsurl()
{
  echo "https://github.com/$(getcomponent 1 "$1")/$(getcomponent 2 "$1")/pulls"
}

gettagurl()
{
  local url="$1"

  if [[ ${url} =~ ^git@github.com: ]]; then
    url="${url/git@github.com:/}"
    echo "https://github.com/$(getcomponent 1 "${url}")/$(getcomponent 2 "${url}" "\.git$")/tags"
  elif [[ ${url} =~ ^git:// ]]; then
    if [[ ${url} =~ ^git://github.com ]]; then
      url="${url/git:\/\/github.com\//}"
      echo "https://github.com/$(getcomponent 1 "${url}")/$(getcomponent 2 "${url}" "\.git$")/tags"
    else
      url=${url%/*}
      echo "${url/git:/https:}"
    fi
  else
    echo "https://github.com/$(getcomponent 1 "${url}")/$(getcomponent 2 "${url}")/tags"
  fi
}

get_rate_limit()
{
  local limit remaining reset startedwith
  local workfile=${GHNOTIFY_WORKDIR}/.startedwith

  webrequest "https://api.github.com/rate_limit"
  limit="$(cat ${WEBWORKFILE} | ${USEPYTHON} -c "${PY_JSON_DATA}" "rate.limit")"
  remaining="$(cat ${WEBWORKFILE} | ${USEPYTHON} -c "${PY_JSON_DATA}" "rate.remaining")"
  reset="$(cat ${WEBWORKFILE} | ${USEPYTHON} -c "${PY_JSON_DATA}" "rate.reset")"

  if [ -f ${workfile} ]; then
    startedwith=$(cat ${workfile})
  else
    startedwith=${remaining}
    echo ${startedwith} >${workfile}
  fi

  echo "limit=${limit} remaining=${remaining} used=$((startedwith - remaining)) reset=$(date --date=@${reset} "+%Y-%m-%d %H:%M:%S")"
}

webrequest()
{
  local url="$1" pages=${2:-N}
  local response result=0 curl page=1

  # Escape +
  url="${url//+/%2B}"

  curl="curl --location --silent --show-error --retry 6 ${AUTHENTICATION} --connect-timeout 30"
  [ "${DIAGNOSTICS}" == "Y" ] && echo "WEB REQUEST : ${curl} \"${url}\""

  rm -f ${WEBWORKFILE} ${WEBWORKFILE}.dmp
  if [ ${pages} == N ]; then
    response="$(${curl} "${url}" -o ${WEBWORKFILE} -D ${WEBWORKFILE}.dmp 2>&1)" || result=1
  else
    echo "[" >> ${WEBWORKFILE}
    while [ ${result} -eq 0 ]; do
      rm -f ${WEBWORKFILE}.tmp ${WEBWORKFILE}.dmp
      response="$(${curl} "${url}?page=${page}&per_page=100" -o ${WEBWORKFILE}.tmp -D ${WEBWORKFILE}.dmp 2>&1)" || result=1
      if [ ${result} -eq 0 ]; then
        [ ${page} -ne 1 ] && echo "," >> ${WEBWORKFILE}
        cat ${WEBWORKFILE}.tmp >> ${WEBWORKFILE}
        grep -q "^Link: .* rel=\"last\"" ${WEBWORKFILE}.dmp || break
        page=$((page + 1))
      fi
    done
    echo "]" >> ${WEBWORKFILE}
  fi
  touch ${WEBWORKFILE}

  if [ "${DIAGNOSTICS}" == "Y" ]; then
    echo "RESPONSE: $(cat ${WEBWORKFILE})"
    echo "PAGES   : ${page}"
    echo "RESULT  : ${result}"
  fi
  if [ ${result} -ne 0 ]; then
    warn "REQUEST: ${url}"
    warn "ERROR  : ${response}"
  fi

  return ${result}
}

htmlsafe()
{
  local html="$1"
  html="${html//&/&amp;}"
  html="${html//</&lt;}"
  html="${html//>/&gt;}"
  echo "${html}"
}

lock_repo()
{
  local lockfile="${GHNOTIFY_LOCKDIR}/$(basename "${1}").lock"

  mkdir -p ${GHNOTIFY_LOCKDIR}
  touch ${lockfile}

  exec 99<${lockfile}
  while ! flock --nonblock --exclusive 99; do
    sleep 1
  done
}

unlock_repo()
{
  flock --unlock 99 2>/dev/null
}

clone_refresh_repo ()
{
  local item="${1}" repodir="${2}" repourl="${3%/*}" repobranch="${3##*/}"

  # Lock this repo to prevent concurrent access (ie. two different branches of same repo)
  lock_repo "${repodir}"
  (
    # Discard output if not logging
    [ "${DEBUG}" == "Y" -o "${DIAGNOSTICS}" == "Y" ] || exec 1>/dev/null

    if [ ! -d ${repodir} ]; then
      git clone ${repourl} ${repodir} 2>&1 || return 1
    fi

    cd ${repodir}
    git checkout ${repobranch} 2>&1 || return 1
    git pull 2>&1 || true
  )

  return ${PIPESTATUS[0]}
}

HTML_MAIN="$(cat <<EOF
<html lang="en-US" dir="LTR">
<head>
  <meta charset="UTF-8" />
  <title>GitHub Updates</title>
</head>
<body dir="LTR" text="#141414" bgcolor="#f0f0f0" link="#176093" alink="#176093" vlink="#176093" style="padding: 10px">
  <table cellpadding="0" cellspacing="0" border="0" dir="LTR" style="
    background-color: #f0f7fc;
    border: 1px solid #a5cae4;
    border-radius: 5px;
    direction: LTR;">
    <tr>
      <td style="
        background-color: #d7edfc;
        padding: 5px 10px;
        border-bottom: 1px solid #a5cae4;
        border-top-left-radius: 4px;
        border-top-right-radius: 4px;
        font-family: 'Trebuchet MS', Helvetica, Arial, sans-serif;
        font-size: 11px;
        line-height: 1.231;">
        <div style="color: #176093; text-decoration:none">GitHub Updates: @@REPO.SUMMARY@@</div>
      </td>
    </tr>
  @@BODY.DETAIL@@
    <tr>
      <td style="
        background-color: #f0f7fc;
        padding: 5px 10px;
        border-top: 1px solid #d7edfc;
        border-bottom-left-radius: 4px;
        border-bottom-right-radius: 4px">
        <table style="font-family: 'Trebuchet MS', Helvetica, Arial, sans-serif;
                      font-size: 9px;
                      color: #176093;
                      text-decoration:none;
                      line-height: 1.231;
                      width:100%">
          <tr>
            <td>@@SCRIPT.STATUS@@</td>
            <td align="right" style="text-align:right;vertical-align:bottom">@@SCRIPT.VERSION@@</td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
EOF
)"

HTML_SUB="$(cat <<EOF
    <tr>
      <td style="
        background-color: #fcfcff;
        color: #141414;
        font-family: 'Trebuchet MS', Helvetica, Arial, sans-serif;
        font-size: 13px;
        line-height: 1.231;">
        <h2 style="font-size: 15pt; font-weight: normal; margin: 10px 10px 0 10px">@@ITEM.TYPE@@: <a href="@@ITEM.URL@@" style="color: #176093; text-decoration: none">@@ITEM.SUBJECT@@</a></h2>
        <hr style="height: 1px; margin: 10px 0; border: 0; color: #d7edfc; background-color: #d7edfc" />
        <table cellpadding="0" cellspacing="0" border="0" width="100%" style="margin: 10px 0 10px">
          <tr valign="top">
            <td width="100%">
              <table cellpadding="0" cellspacing="0" border="0" width="100%" style="font-size: 9pt; line-height: 1.4">
@@ITEM.ROWS@@
              </table>
            </td>
          </tr>
        </table>
      </td>
    </tr>
EOF
)"

GITAPI="https://api.github.com/repos"
FIELDSEP=$'\001'
NEWLINE=$'\012'

DEBUG=N
DIAGNOSTICS=N
NOEMAIL=N
COMMITS=
PULLREQ=
RELEASES=
FILTER=,
SHOWLIST=N

for arg in $@; do
  case "${arg}" in
    debug)    NOEMAIL=Y; export DEBUG=Y;;
    diags)    DIAGNOSTICS=Y;;
    noemail)  NOEMAIL=Y;;
    commits)  COMMITS=Y;;
    pulls)    PULLREQ=Y;;
    releases|tags) RELEASES=Y;;
    item=*|items=*|filter=*|filters=*)
              FILTER=${FILTER}${arg#*=},;;
    list)     SHOWLIST=Y;;
    noclean)  trap 'rm -rf -- "${PIDFILE}"' EXIT;;
  esac
done

if [ -z "${COMMITS}${PULLREQ}${RELEASES}" ]; then
  COMMITS=Y
  PULLREQ=Y
  RELEASES=N
fi

COMMITS=${COMMITS:-N}
PULLREQ=${PULLREQ:-N}
RELEASES=${RELEASES:-N}

# Try and find a usable mail transfer agent (MTA).
#
# A list of possible MTA clients is tested for, and when multiple MTA clients are
# present the last one will be used, so order them in ascending (left-to-right)
# order of priority.
#
# msmtp_safe is a personalised wrapper for msmpt that will retry transmission
# up to 10 times in the event of msmpt timing out.
#
for emailclient in sendmail ssmtp msmtp msmtp_safe; do
  command -v ${emailclient} 2>&1 >/dev/null && BIN_MTA="$(command -v ${emailclient})"
done

# Use a default email address if available
EMAILTO="$(grep MAILTO /etc/crontab 2>/dev/null | awk -F= '{print $2}')"

# Fixup config and data paths

# Legacy config file
[ -f ~/${GHNOTIFY_DATA} ]       && mv ~/${GHNOTIFY_DATA} ~/${GHNOTIFY_CDATA}
[ -f ${BIN}/${GHNOTIFY_DATA} ]  && mv ${BIN}/${GHNOTIFY_DATA} ${BIN}/${GHNOTIFY_CDATA}

# Absolute paths
[ -f ${BIN}/${GHNOTIFY_CONF} ]  && GHNOTIFY_CONF="${BIN}/${GHNOTIFY_CONF}"   || GHNOTIFY_CONF=~/${GHNOTIFY_CONF}
GHNOTIFY_CDATA=$(dirname "${GHNOTIFY_CONF}")/${GHNOTIFY_CDATA}
GHNOTIFY_PDATA=$(dirname "${GHNOTIFY_CONF}")/${GHNOTIFY_PDATA}
GHNOTIFY_RDATA=$(dirname "${GHNOTIFY_CONF}")/${GHNOTIFY_RDATA}

# If an absolute path then use it if it exists
if ! [ "${GHNOTIFY_GITDIR:0:1}" == "/" -a -d "${GHNOTIFY_GITDIR}" ]; then
  [ -d ${BIN}/${GHNOTIFY_GITDIR} ] && GHNOTIFY_GITDIR="${BIN}/${GHNOTIFY_GITDIR}" || GHNOTIFY_GITDIR=~/${GHNOTIFY_GITDIR}
  mkdir -p ${GHNOTIFY_GITDIR}
fi

# Optionally load GIT authentication and override settings, eg. EMAILTO, GHNOTIFY_?DATA etc.
[ -f ~/.git.conf ] && source ~/.git.conf

[ -n "${GIT_USERNAME}" -a -n "${GIT_PASSWORD}" ] && AUTHENTICATION="-u ${GIT_USERNAME}:${GIT_PASSWORD}"

[ ! -f ${GHNOTIFY_CONF} ] && die 1 "Cannot find configuration file [${GHNOTIFY_CONF}]"
[ ! -x ${BIN_MTA} ]       && die 1 "Email client not found [${BIN_MTA}]"
[ -d ${GHNOTIFY_GITDIR} ] || die 1 "Unable to locate git directory ${GHNOTIFY_GITDIR}"

#Stop reporting new commits if there has been no build activity for longer than the specified period
if [ -f ${CHECK_FILE} -a ${CHECK_INTERVAL_DAYS} -ne 0 ]; then
  DELTA=$(($(date +%s) - $(stat -c%Y ${CHECK_FILE})))
  [ ${DELTA} -ge $((${CHECK_INTERVAL_DAYS} * 24 * 60 * 60)) ] && die 0 "Exceeded check interval ${CHECK_INTERVAL_DAYS} days"
fi

if [ "${DEBUG}" == "Y" ]; then
  echo "Commits       : ${COMMITS}" | logger init
  echo "Pull Requests : ${PULLREQ}" | logger init
  echo "Releases      : ${RELEASES}" | logger init
  echo "Using Python  : ${USEPYTHON}" | logger init
  echo "Config File   : ${GHNOTIFY_CONF}" | logger init
  echo "Commit DB     : ${GHNOTIFY_CDATA}" | logger init
  echo "Pull Req DB   : ${GHNOTIFY_PDATA}" | logger init
  echo "Release DB    : ${GHNOTIFY_RDATA}" | logger init
  echo "Git Directory : ${GHNOTIFY_GITDIR}" | logger init
  echo "Temp Directory: ${GHNOTIFY_WORKDIR}" | logger init
  echo "MTA Path      : ${BIN_MTA}" | logger init
  echo "Github Limits : $(get_rate_limit)" | logger init
fi

if [ "${COMMITS}" == "Y" ]; then
  [ ! -f ${GHNOTIFY_CDATA} ] && touch ${GHNOTIFY_CDATA}
  cp ${GHNOTIFY_CDATA} ${GHNOTIFY_CTEMP}
fi

if [ "${PULLREQ}" == "Y" ]; then
  [ ! -f ${GHNOTIFY_PDATA} ] && touch ${GHNOTIFY_PDATA}
  cp ${GHNOTIFY_PDATA} ${GHNOTIFY_PTEMP}
fi

if [ "${RELEASES}" == "Y" ]; then
  [ ! -f ${GHNOTIFY_RDATA} ] && touch ${GHNOTIFY_RDATA}
  cp ${GHNOTIFY_RDATA} ${GHNOTIFY_RTEMP}
fi

HISTORY_OWNER_REPO=()

findinlist()
{
  local item="${1}" key

  for key in "${!HISTORY_OWNER_REPO[@]}"; do
    [ "${HISTORY_OWNER_REPO[$key]}" == "${item}" ] && return 0
  done
  return 1
}

getworkqueue()
{
  local owner_repo_branch owner_repo name safe_name isduplicate
  local plast pstatus clast cstatus rlast rstatus
  local item=0 izeros

  while read -r owner_repo_branch name; do
    [ -z ${owner_repo_branch} ] && continue

    item=$((item+1))
    izeros="$(printf "%04d" ${item})"

    # Ignore any item not in FILTER
    [ "${FILTER}" != "," -a "${FILTER/,${item},/}" == "${FILTER}" -a "${FILTER/,${izeros},/}" == "${FILTER}" ] && continue

    safe_name="$(htmlsafe "${name}")"

    owner_repo="${owner_repo_branch%/*}"

    if findinlist "${owner_repo}"; then
      isduplicate=Y
    else
      isduplicate=N
      HISTORY_OWNER_REPO+=("${owner_repo}")
    fi

    if [ "${PULLREQ}" == "Y" -a "${isduplicate}" == "N" ] && ! [[ ${owner_repo_branch} =~ ^git[@:] ]]; then
      pstatus=Y
      plast="$(grep "^${owner_repo_branch} " ${GHNOTIFY_PTEMP} | tail -1 | awk '{ print $2 }')"
      [ -z "${plast}" ] && echo "${owner_repo_branch} 0" >> ${GHNOTIFY_PTEMP}
    else
      plast=
      pstatus=N
    fi

    if [ "${COMMITS}" == "Y" ]; then
      cstatus=Y
      clast="$(grep "^${owner_repo_branch} " ${GHNOTIFY_CTEMP} | tail -1 | awk '{ print $2 }')"
      [ -z "${clast}" ] && echo "${owner_repo_branch} 0" >> ${GHNOTIFY_CTEMP}
      [ "${clast}" = "0" ] && clast=
    else
      clast=
      cstatus=N
    fi

    if [ "${RELEASES}" == "Y" -a "${isduplicate}" == "N" ]; then
      rstatus=Y
      rlast="$(grep "^${owner_repo_branch} " ${GHNOTIFY_RTEMP} | tail -1 | cut -d' ' -f2-)"
      [ -z "${rlast}" ] && echo "${owner_repo_branch} []" >> ${GHNOTIFY_RTEMP}
    else
      rlast=
      rstatus=N
    fi

    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|\n" "${izeros}" "${plast:-unknown}" "${clast:-unknown}" "${rlast:-unknown}" "${pstatus}" "${cstatus}" "${rstatus}" "${owner_repo_branch}" "${safe_name}"
#[ ${item} -ge 1 ] && break
  done <<< "$(grep -v "^#" ${GHNOTIFY_CONF})"
}

process_work_items()
{
  local qitem qplast qclast qrlast qpstatus qcstatus qrstatus qownerrepobranch qname
  local jobn=0

  while IFS="|" read -r qitem qplast qclast qrlast qpstatus qcstatus qrstatus qownerrepobranch qname; do
    jobn=$((jobn + 1))

    echo "Processing ${qname}" | logger ${qitem}

    if [ ${SHOWLIST} != Y ]; then
      if [ "${DEBUG}" == "Y" -o "${DIAGNOSTICS}" == "Y" ]; then
        ( process_work_item "${qitem}" "${qownerrepobranch}" "${qname}" "${qplast}" "${qclast}" "${qrlast}" "${qpstatus}" "${qcstatus}" "${qrstatus}" | logger "${qitem}" ) &
      else
        process_work_item "${qitem}" "${qownerrepobranch}" "${qname}" "${qplast}" "${qclast}" "${qrlast}" "${qpstatus}" "${qcstatus}" "${qrstatus}" &
      fi

      if [ ${jobn} -ge ${MAXJOBS} ]; then
        wait
        jobn=0
      fi
    fi
  done <<< "$(getworkqueue)"
  wait

  if [ $(ls -1 ${GHNOTIFY_WORKDIR}/*.err 2>/dev/null | wc -l) -ne 0 ]; then
    cat ${GHNOTIFY_WORKDIR}/*.err >&2
    die 1 "An error has occurred"
  fi
}

process_work_item()
{
  local item="$1" owner_repo_branch="$2" name="$3" plast="$4" clast="$5" rlast="$6" pstatus="$7" cstatus="$8" rstatus="$9"
  local workfile=${GHNOTIFY_WORKDIR}/${item}
  local githash gitrepodir

  WEBWORKFILE=${workfile}.webrequest

  local pulls=${workfile}.pull comms=${workfile}.commit rels=${workfile}.release

  local pdata=${pulls}.dat perror=${pulls}.err punavailable=${pulls}.unavailable pupdate=${pulls}.update pitem=${pulls}.item
  local cdata=${comms}.dat cerror=${comms}.err cunavailable=${comms}.unavailable cupdate=${comms}.update citem=${comms}.item
  local rdata=${rels}.dat  rerror=${rels}.err  runavailable=${rels}.unavailable  rupdate=${rels}.update  ritem=${rels}.item

  local pcrnt pactual pnodata pneedupdate=N
  local ccrnt cactual cnodata cneedupdate=N
  local rcrnt ractual rnodata rneedupdate=N

  if [[ ${owner_repo_branch} =~ ^git[@:] ]]; then
    githash="$(echo "${owner_repo_branch%/*}" | md5sum | awk '{print $1}')"
    gitrepodir="${GHNOTIFY_GITDIR}/${githash}"
    if ! clone_refresh_repo "${item}" "${gitrepodir}" "${owner_repo_branch}"; then
      echo "ERROR: Unable to clone/refresh repository [${owner_repo_branch%/*}], branch [${owner_repo_branch##*/}]" >${cerror}
      return 1
    fi
    grep -qE "^${githash}" ${GHNOTIFY_GITDIR}/.map || echo "${githash} ${owner_repo_branch%/*}" >>${GHNOTIFY_GITDIR}/.map
  fi

  if [ "${pstatus}" == "Y" ]; then
    if ! getpulldetails "${item}"  "${pdata}" "${owner_repo_branch}" "${plast:-0}"; then
      echo "ERROR: Failed to obtain pull request list for repository [${owner_repo_branch}]" >${perror}
      return 1
    fi
    if [ "$(cat ${pdata})" == "ERROR" ]; then
      echo "${name}" >${punavailable}
    else
      pcrnt="$(head -1 "${pdata}")"
      pactual="$(tail -n +2 "${pdata}")"

      [ "${plast}" == "unknown" ] && pneedupdate=Y
      [ -z "${pactual}" -o "${pcrnt}" == "${plast}" -o "${plast}" == "unknown" ] && pnodata=Y || pnodata=N
      [ -z "${pcrnt}" ] && pcrnt="0"

      [ "${DEBUG}" == "Y" ] && echo "Last known pull request #${plast}, current remote pull request #${pcrnt}"

      [ "${plast}" == "unknown" -a -n "${pcrnt}" ] && plast="${pcrnt}"

      if [ "${pnodata}" == "N" ]; then
        echo "${pactual}" >${pdata}.actual
        output_pull_requests "${pdata}.actual" "${owner_repo_branch}" "${name}" > ${pitem}
        pneedupdate=Y
      fi
      [ "${pneedupdate}" == "Y" ] && echo "${pcrnt}|${owner_repo_branch}|${name}" > ${pupdate}
    fi
  fi

  if [ "${cstatus}" == "Y" ]; then
    if ! getlatestsha "${item}" "${cdata}" "${owner_repo_branch}" "${gitrepodir}"; then
      echo "ERROR: Failed to obtain current SHA for repository [${owner_repo_branch}]" >${cerror}
      return 1
    fi

    ccrnt="$(head -1 "${cdata}")"
    if [ -z "${ccrnt}" ]; then
      echo "${name}" >${cunavailable}
    else
      [ "${clast}" == "unknown" ] && cneedupdate=Y
      [ "${ccrnt}" == "${clast}" -o "${clast}" == "unknown" ] && cnodata=Y || cnodata=N

      [ "${DEBUG}" == "Y" ] && echo "Last known commit hash ${clast:0:7}, current remote commit hash ${ccrnt:0:7}"

      [ "${clast}" == "unknown" -a -n "${ccrnt}" ] && clast="${ccrnt}"

      if [ "${cnodata}" == "N" ]; then
        if getcommitdetails "${item}" "${cdata}.actual" "${owner_repo_branch}" "${gitrepodir}" "${clast}" "${ccrnt}"; then
          if [ -s ${cdata}.actual -a "$(cat ${cdata}.actual)" != "ERROR" ]; then
            output_commits "${cdata}.actual" "${owner_repo_branch}" "${name}" > ${citem}
            cneedupdate=Y
          fi
        else
          echo "ERROR: Failed to obtain commit comparison for repository [${owner_repo_branch}]" >${cerror}
          return 1
        fi
      fi
      [ "${cneedupdate}" == "Y" ] && echo "${ccrnt}|${owner_repo_branch}|${name}" > ${cupdate}
    fi
  fi

  if [ "${rstatus}" == "Y" ]; then
    if ! getalltags "${item}" "${rdata}" "${owner_repo_branch}" "${gitrepodir}"; then
      echo "ERROR: Failed to obtain current tags for repository [${owner_repo_branch}]" >${cerror}
      return 1
    fi

    rcrnt="$(head -1 "${rdata}")"
    if [ -z "${rcrnt}" ]; then
      echo "${name}" >${runavailable}
    else
      [ "${rlast}" == "unknown" ] && rneedupdate=Y
      [ "${rcrnt}" == "${rlast}" -o "${rlast}" == "unknown" ] && rnodata=Y || rnodata=N

      [ "${DEBUG}" == "Y" ] && echo -e "Last known tags  ${rlast}\nCrnt remote tags ${rcrnt}"

      [ "${rlast}" == "unknown" -a -n "${rcrnt}" ] && rlast="${rcrnt}"

      if [ "${rnodata}" == "N" ]; then
        if getnewtagdetails "${item}" "${rdata}.actual" "${owner_repo_branch}" "${gitrepodir}" "${rlast}" "${rcrnt}"; then
          if [ -s ${rdata}.actual -a "$(cat ${rdata}.actual)" != "ERROR" ]; then
            output_tags "${rdata}.actual" "${owner_repo_branch}" "${name}" > ${ritem}
            rneedupdate=Y
          fi
        else
          echo "ERROR: Failed to obtain tag comparison for repository [${owner_repo_branch}]" >${rerror}
          return 1
        fi
      fi
      [ "${rneedupdate}" == "Y" ] && echo "${rcrnt}|${owner_repo_branch}|${name}" > ${rupdate}
    fi
  fi

  [ -n "${gitrepodir}" ] && unlock_repo
}

output_pull_requests()
{
  local datafile="$1" owner_repo_branch="$2" name="$3"
  local url item rows even row color avatar_url committer title avatar

  url="$(getpullsurl "${owner_repo_branch}")"

  item="${HTML_SUB}"
  item="${item//@@ITEM.TYPE@@/Pulls}"
  item="${item//@@ITEM.URL@@/${url}}"
  item="${item//@@ITEM.SUBJECT@@/${name}}"
  rows=
  even=Y
  while read -r avatar_url committer title; do
    [ "${even}" == "Y" ] && color="#f0f0f0" || color="#fcfcff"
    avatar="<img src=\"${avatar_url}\" style=\"height: 20px; width: 20px\" />"
    row="<tr style=\"background-color: ${color}; vertical-align: top\">"
    row="${row}<td style=\"padding-left: 10px; padding-right:10px; padding-top:2px\">${avatar}</td>"
    row="${row}<td style=\"padding-right: 10px; width: 100%\">${title}<br>"
    row="${row}<span style=\"font-size: 6pt; color: grey\">${committer//${FIELDSEP}/ }</span></td>"
    row="${row}</tr>"
    [ -n "${rows}" ] && rows="${rows}${NEWLINE}${row}" || rows="${row}"
    [ "${even}" == "Y" ] && even=N || even=Y
  done < ${datafile}

  echo "${item//@@ITEM.ROWS@@/${rows}}"
}

output_commits()
{
  local datafile="$1" owner_repo_branch="$2" name="${3}"
  local url item rows even row color avatar_url committer title avatar

  url="$(getcommitsurl "${owner_repo_branch}")"

  item="${HTML_SUB}"
  item="${item//@@ITEM.TYPE@@/Commits}"
  item="${item//@@ITEM.URL@@/${url}}"
  item="${item//@@ITEM.SUBJECT@@/${name}}"
  rows=
  even=Y
  while read -r avatar_url committer title; do
    [ "${even}" == "Y" ] && color="#f0f0f0" || color="#fcfcff"
    avatar="<img src=\"${avatar_url}\" style=\"height: 20px; width: 20px\" />"
    row="<tr style=\"background-color: ${color}; vertical-align: top\">"
    row="${row}<td style=\"padding-left: 10px; padding-right:10px; padding-top:2px\">${avatar}</td>"
    row="${row}<td style=\"padding-right: 10px; width: 100%\">${title}<br>"
    row="${row}<span style=\"font-size: 6pt; color: grey\">${committer//${FIELDSEP}/ }</span></td>"
    row="${row}</tr>"
    [ -n "${rows}" ] && rows="${rows}${NEWLINE}${row}" || rows="${row}"
    [ "${even}" == "Y" ] && even=N || even=Y
  done < ${datafile}

  echo "${item//@@ITEM.ROWS@@/${rows}}"
}

output_tags()
{
  local datafile="$1" owner_repo_branch="$2" name="${3}"
  local url item rows even row color avatar_url committer title avatar
  local committer=$(getcomponent 1 "${owner_repo_branch}")

  url="$(gettagurl "${owner_repo_branch}")"

  item="${HTML_SUB}"
  item="${item//@@ITEM.TYPE@@/Tags}"
  item="${item//@@ITEM.URL@@/${url}}"
  item="${item//@@ITEM.SUBJECT@@/${name}}"
  rows=
  even=Y
  while read -r avatar_url title; do
    [ "${even}" == "Y" ] && color="#f0f0f0" || color="#fcfcff"
    avatar="<img src=\"${avatar_url}\" style=\"height: 20px; width: 20px\" />"
    row="<tr style=\"background-color: ${color}; vertical-align: top\">"
    row="${row}<td style=\"padding-left: 10px; padding-right:10px; padding-top:2px\">${avatar}</td>"
    row="${row}<td style=\"padding-right: 10px; width: 100%\">${title}<br>"
    row="${row}<span style=\"font-size: 6pt; color: grey\">${committer//${FIELDSEP}/ }</span></td>"
    row="${row}</tr>"
    [ -n "${rows}" ] && rows="${rows}${NEWLINE}${row}" || rows="${row}"
    [ "${even}" == "Y" ] && even=N || even=Y
  done < ${datafile}

  echo "${item//@@ITEM.ROWS@@/${rows}}"
}

get_processed_count()
{
  cd ${GHNOTIFY_WORKDIR}
  echo $(ls -1 * 2>/dev/null | grep -v webrequest | cut -d. -f1 | sort -u | wc -l)
}

get_item_count()
{
  cd ${GHNOTIFY_WORKDIR}
  echo $(ls -1 *.item 2>/dev/null | cut -d. -f1 | sort -u | wc -l)
}

get_updated_count()
{
  cd ${GHNOTIFY_WORKDIR}
  echo $(ls -1 *.update 2>/dev/null | cut -d. -f1 | sort -u | wc -l)
}

get_unavailable_count()
{
  cd ${GHNOTIFY_WORKDIR}
  echo $(ls -1 *.unavailable 2>/dev/null | cut -d. -f1 | sort -u | wc -l)
}

get_item_summary()
{
  local item newvalue owner_repo_branch name summary

  cd ${GHNOTIFY_WORKDIR}
  for item in $(ls -1 *.item 2>/dev/null | cut -d. -f1 | sort -u); do
    if [ $(ls -1 ${item}.*.update | wc -l) -ne 0 ]; then
      while IFS="|" read -r newvalue owner_repo_branch name; do
        summary+=", ${name}"
        break
      done <<< "$(cat ${item}.*.update)"
    fi
  done
  echo "${summary:2}"
}

get_unavailable_details()
{
  local item status

  cd ${GHNOTIFY_WORKDIR}
  for item in $(ls -1 *.unavailable 2>/dev/null | cut -d. -f1 | sort -u); do
    status+="<br>${NEWLINE}Unavailable: <span style=\"color:red\">$(cat ${item}.*.unavailable | head -1)</span>"
  done
  echo "${status}"
}

get_msg_body()
{
  local body item

  cd ${GHNOTIFY_WORKDIR}
  for item in $(ls -1 *.update | cut -d. -f1 | sort -u); do
    for subitem in pull commit release; do
      if [ -f ${item}.${subitem}.update -a -f ${item}.${subitem}.item ]; then
        [ -n "${body}" ] && body+="${NEWLINE}"
        body+="$(cat ${item}.${subitem}.item)"
      fi
    done
  done

  echo "${body}"
}

save_updated_details()
{
  local item newvalue owner_repo_branch name
  local target

  cd ${GHNOTIFY_WORKDIR}
  for item in $(ls -1 *.update 2>/dev/null | sort); do
    while IFS="|" read -r newvalue owner_repo_branch name; do
      break
    done <<< "$(cat ${item})"

    if [[ ${item} =~ .*\.pull\.update ]]; then
      target=${GHNOTIFY_PTEMP}
    elif [[ ${item} =~ .*\.commit\.update ]]; then
      target=${GHNOTIFY_CTEMP}
    elif [[ ${item} =~ .*\.release\.update ]]; then
      target=${GHNOTIFY_RTEMP}
    fi

    sed -i "s${FIELDSEP}^${owner_repo_branch} .*\$${FIELDSEP}${owner_repo_branch} ${newvalue}${FIELDSEP}" ${target}
  done
}

process_work_items

if [ "${DEBUG}" == "Y" ]; then
  echo "Github Limits : $(get_rate_limit)" | logger exit
fi

if [ $(get_item_count) -ne 0 ]; then
  rm -fr ${TMPFILE}

  if [ "${NOEMAIL}" == "N" ]; then
    echo "To: ${EMAILTO}" >> ${TMPFILE}
    echo "Subject: GitHub Updates" >> ${TMPFILE}
    echo "Content-Type: text/html; charset=utf-8" >> ${TMPFILE}
    echo "Content-Transfer-Encoding: quoted-printable" >>${TMPFILE}
    echo "" >>${TMPFILE}
  fi

  STATUS="Processed: $(get_processed_count), Unavailable: $(get_unavailable_count)"
  if [ $(get_unavailable_count) -ne 0 ]; then
    STATUS+="<span>$(get_unavailable_details)</span>"
  fi

  PAGE="${HTML_MAIN}"
  PAGE="${PAGE//@@REPO.SUMMARY@@/$(get_item_summary)}"
  PAGE="${PAGE//@@BODY.DETAIL@@/$(get_msg_body)}"
  PAGE="${PAGE//@@SCRIPT.STATUS@@/${STATUS}}"
  PAGE="${PAGE//@@SCRIPT.VERSION@@/${VERSION}}"

  if [ "${NOEMAIL}" == "N" ]; then
    echo "${PAGE}" | qprint -be >> ${TMPFILE}
    cat ${TMPFILE} | ${BIN_MTA} || die 1 "ERROR: Failed to send email"
  else
    echo "${PAGE}" >> ${TMPFILE}
    mv ${TMPFILE} ${BIN}/email.html
  fi
fi

[ $(get_updated_count) -ne 0 ] && save_updated_details

if [ "${DEBUG}" == "N" ]; then
  [ -f ${GHNOTIFY_CTEMP} ] && cp ${GHNOTIFY_CTEMP} ${GHNOTIFY_CDATA}
  [ -f ${GHNOTIFY_PTEMP} ] && cp ${GHNOTIFY_PTEMP} ${GHNOTIFY_PDATA}
  [ -f ${GHNOTIFY_RTEMP} ] && cp ${GHNOTIFY_RTEMP} ${GHNOTIFY_RDATA}
fi

exit 0
