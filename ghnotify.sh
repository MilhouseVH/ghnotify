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
VERSION="v0.2.0"

BIN=$(readlink -f $(dirname $0))

DEFAULTMAXJOBS=$(($(nproc) * 10))
MAXJOBS=${MAXJOBS:-${DEFAULTMAXJOBS}}

# Stop sending emails if the specified number of days have elapsed since
# the last modification to the CHECK_FILE.
CHECK_INTERVAL_DAYS=14
CHECK_FILE=${BIN}/patches.dat

PY_COMMIT_PR='
import os, sys, json, datetime, urllib2, codecs, re

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
    sys.stderr.write("[%s] %s\n" % (ditem, msg))

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
    return input.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
  else:
    return input

data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))

if "message" in jdata:
  print("ERROR")
  sys.exit(0)

dtype = sys.argv[1]
ditem = sys.argv[2]

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
      
      print("%s %s %s" % (avatar_url, htmlsafe(commitdata.replace(" ", "\001")), message))

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
    if len(sys.argv) == 4:
      tmp = sys.argv[3]
      lastpr = int(tmp) if tmp and tmp != "unknown" else 0

    if len(jdata) != 0:
      print(jdata[0]["number"])

    for pr in [x for x in jdata if x["number"] > lastpr]:
      avatar_url = getavatar(avatars, pr["user"])
      author = pr["user"]["login"]
      pulldata = "%s authored %s" % (author, whendelta(pr["created_at"]))
      message = "<a href=\"%s\">#%s</a> %s" % (pr["html_url"], pr["number"], htmlsafe(pr["title"]))
      
      print("%s %s %s" % (avatar_url, htmlsafe(pulldata.replace(" ", "\001")), message))

      debug("  Message : %s" % message)
      debug("  Avatar  : %s" % avatar_url)
      debug("  Who/When: %s" % pulldata)
  except:
    raise
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

getcomponent()
{
  local field="$1" string="$2"
  echo "${string}" | cut -d/ -f${field}
}

getlatestsha()
{
  local item="$1" owner_repo_branch="$2"
  local URL RESPONSE

  URL="${GITAPI}/$(getcomponent 1 "${owner_repo_branch}")/$(getcomponent 2 "${owner_repo_branch}")/commits?per_page=1&sha=$(getcomponent 3- "${owner_repo_branch}")"
  RESPONSE="$(webrequest "${URL}")" || return 1

  echo "${RESPONSE}" | python -c '
import sys, json
data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))
for item in jdata:
  if "sha" in item:
    print("%s" % item["sha"])
  break
'
  return 0
}

getcommitdetails()
{
  local item="$1" owner_repo_branch="$2" lastvalue="$3" crntvalue="$4"
  local URL RESPONSE

  URL="${GITAPI}/$(getcomponent 1 "${owner_repo_branch}")/$(getcomponent 2 "${owner_repo_branch}")/compare/${lastvalue}...${crntvalue}"
  RESPONSE="$(webrequest "${URL}")" || return 1
  [ "${DEBUG}" = Y ] && echo "${RESPONSE}" >${BIN}/dbg_commits_$(echo "${owner_repo_branch}"|sed "s#/#_#g")

  echo "${RESPONSE}" | python -c "${PY_COMMIT_PR}" commits "${item}"

  return $?
}

getpulldetails()
{
  local item="$1" owner_repo_branch="$2" lastvalue="$3"
  local URL RESPONSE

  URL="${GITAPI}/$(getcomponent 1 "${owner_repo_branch}")/$(getcomponent 2 "${owner_repo_branch}")/pulls"
  RESPONSE="$(webrequest "${URL}")" || return 1
  [ "${DEBUG}" = Y ] && echo "${RESPONSE}" >${BIN}/dbg_pulls_$(echo "${owner_repo_branch}"|sed "s#/#_#g")
  echo "${RESPONSE}" | python -c "${PY_COMMIT_PR}" pulls "${item}" "${lastvalue}"

  return $?
}

getcommitsurl()
{
  echo "https://github.com/$(getcomponent 1 "$1")/$(getcomponent 2 "$1")/commits/$(getcomponent 3 "$1")"
}

getpullsurl()
{
  echo "https://github.com/$(getcomponent 1 "$1")/$(getcomponent 2 "$1")/pulls"
}

webrequest()
{
  local url="$1" response result=0 curl

  # Escape +
  url="${url//+/%2B}"

  curl="curl --location --silent --show-error --retry 6 ${AUTHENTICATION} --connect-timeout 30"
  [ "${DIAGNOSTICS}" == Y ] && echo -e "\nREQUEST : ${curl} \"${url}\"" >&2
  response="$(${curl} "${url}" 2>&1)" || result=1
  if [ "${DIAGNOSTICS}" == Y ]; then
    echo "RESPONSE: ${response}" >&2
    echo "RESULT  : ${result}" >&2
  elif [ ${result} -ne 0 ]; then
    warn "REQUEST: ${url}"
    warn "ERROR: ${response}"
  fi
  echo "${response}"
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

GHNOTIFY_CONF=ghnotify.conf
GHNOTIFY_DATA=ghnotify.dat
GHNOTIFY_CDATA=ghnotify.commits
GHNOTIFY_PDATA=ghnotify.pulls

GHNOTIFY_WORKDIR=$(mktemp -d)
GHNOTIFY_PTEMP=${GHNOTIFY_WORKDIR}/.ptemp
GHNOTIFY_CTEMP=${GHNOTIFY_WORKDIR}/.ctemp
TMPFILE=${GHNOTIFY_WORKDIR}/.tmpfile

trap "rm -rf ${GHNOTIFY_WORKDIR}" EXIT

DEBUG=N
DIAGNOSTICS=N
NOEMAIL=N
COMMITS=
PULLREQ=

for arg in $@; do
  case "${arg}" in
    debug)   NOEMAIL=Y; export DEBUG=Y;;
    diags)   DIAGNOSTICS=Y;;
    noemail) NOEMAIL=Y;;
    commits) COMMITS=Y;;
    pulls)   PULLREQ=Y;;
  esac
done

[ "${COMMITS}" == "Y" -a "${PULLREQ}" == "" ] && PULLREQ=N
[ "${PULLREQ}" == "Y" -a "${COMMITS}" == "" ] && COMMITS=N
[ $COMMITS ] || COMMITS=Y
[ $PULLREQ ] || PULLREQ=Y

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

[ -f ~/${GHNOTIFY_DATA} ]       && mv ~/${GHNOTIFY_DATA} ~/${GHNOTIFY_CDATA}
[ -f ${BIN}/${GHNOTIFY_DATA} ]  && mv ${BIN}/${GHNOTIFY_DATA} ${BIN}/${GHNOTIFY_CDATA}

[ -f ${BIN}/${GHNOTIFY_CONF} ]  && GHNOTIFY_CONF="${BIN}/${GHNOTIFY_CONF}"   || GHNOTIFY_CONF=~/${GHNOTIFY_CONF}
[ -f ${BIN}/${GHNOTIFY_CDATA} ] && GHNOTIFY_CDATA="${BIN}/${GHNOTIFY_CDATA}" || GHNOTIFY_CDATA=~/${GHNOTIFY_CDATA}
[ -f ${BIN}/${GHNOTIFY_PDATA} ] && GHNOTIFY_PDATA="${BIN}/${GHNOTIFY_PDATA}" || GHNOTIFY_PDATA=~/${GHNOTIFY_PDATA}

# Optionally load GIT authentication and override settings, eg. EMAILTO, GHNOTIFY_?DATA etc.
[ -f ~/.git.conf ] && source ~/.git.conf

[ -n "${GIT_USERNAME}" -a -n "${GIT_PASSWORD}" ] && AUTHENTICATION="-u ${GIT_USERNAME}:${GIT_PASSWORD}"

[ ! -f ${GHNOTIFY_CONF} ] && die 1 "Cannot find configuration file [${GHNOTIFY_CONF}]"
[ ! -x ${BIN_MTA} ]       && die 1 "Email client not found [${BIN_MTA}]"

#Stop reporting new commits if there has been no build activity for longer than the specified period
if [ -f ${CHECK_FILE} -a ${CHECK_INTERVAL_DAYS} -ne 0 ]; then
  DELTA=$(($(date +%s) - $(stat -c%Y ${CHECK_FILE})))
  [ ${DELTA} -ge $((${CHECK_INTERVAL_DAYS} * 24 * 60 * 60)) ] && die 0 "Exceeded check interval ${CHECK_INTERVAL_DAYS} days"
fi

if [ ${COMMITS} = Y ]; then
  [ ! -f ${GHNOTIFY_CDATA} ] && touch ${GHNOTIFY_CDATA}
  cp ${GHNOTIFY_CDATA} ${GHNOTIFY_CTEMP}
fi

if [ ${PULLREQ} = Y ]; then
  [ ! -f ${GHNOTIFY_PDATA} ] && touch ${GHNOTIFY_PDATA}
  cp ${GHNOTIFY_PDATA} ${GHNOTIFY_PTEMP}
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
  local owner_repo_branch owner_repo name processed safe_name isduplicate
  local plast pstatus clast cstatus

  while read -r owner_repo_branch name; do
    [ -z ${owner_repo_branch} ] && continue

    processed=$((processed+1))
    safe_name="$(htmlsafe "${name}")"

    owner_repo="${owner_repo_branch%/*}"

    if findinlist "${owner_repo}"; then
      isduplicate=Y
    else
      isduplicate=N
      HISTORY_OWNER_REPO+=("${owner_repo}")
    fi

    if [ ${PULLREQ} == Y -a ${isduplicate} == N ]; then
      pstatus=Y
      plast="$(grep "^${owner_repo_branch} " ${GHNOTIFY_PTEMP} | tail -1 | awk '{ print $2 }')"
      [ -z "${plast}" ] && echo "${owner_repo_branch} 0" >> ${GHNOTIFY_PTEMP}
    else
      plast=
      pstatus=N
    fi

    if [ ${COMMITS} == Y ]; then
      cstatus=Y
      clast="$(grep "^${owner_repo_branch} " ${GHNOTIFY_CTEMP} | tail -1 | awk '{ print $2 }')"
      [ -z "${clast}" ] && echo "${owner_repo_branch} 0" >> ${GHNOTIFY_CTEMP}
    else
      clast=
      cstatus=N
    fi

    printf "%04d|%s|%s|%s|%s|%s|%s|\n" "${processed}" "${plast:-unknown}" "${clast:-unknown}" "${pstatus}" "${cstatus}" "${owner_repo_branch}" "${safe_name}"
  done <<< "$(grep -v "^#" ${GHNOTIFY_CONF})"
}

process_work_items()
{
  local qitem qplast qclast qpstatus qcstatus qownerrepobranch qname
  local jobn=0

  while read -r qitem qplast qclast qpstatus qcstatus qownerrepobranch qname; do
    jobn=$((jobn + 1))
    echo "[${qitem}] Processing ${qname}"
    process_work_item "${qitem}" "${qownerrepobranch}" "${qname}" "${qplast}" "${qclast}" "${qpstatus}" "${qcstatus}" &

    if [ ${jobn} -ge ${MAXJOBS} ]; then
      wait
      jobn=0
    fi
  done <<< "$(getworkqueue | sed 's/|/ /g')"
  wait

  if [ $(ls -1 ${GHNOTIFY_WORKDIR}/*.err 2>/dev/null | wc -l) -ne 0 ]; then
    cat ${GHNOTIFY_WORKDIR}/*.err
    die 1 "An error has occurred"
  fi
}

process_work_item()
{
  local item="$1" owner_repo_branch="$2" name="$3" plast="$4" clast="$5" pstatus="$6" cstatus="$7"
  local workfile=${GHNOTIFY_WORKDIR}/${item}

  local pulls=${workfile}.pull comms=${workfile}.commit
  local pdata=${pulls}.dat perror=${pulls}.err punavailable=${pulls}.unavailable pupdate=${pulls}.update pitem=${pulls}.item
  local cdata=${comms}.dat cerror=${comms}.err cunavailable=${comms}.unavailable cupdate=${comms}.update citem=${comms}.item

  local pcrnt pactual pnodata pneedupdate=N
  local ccrnt cactual cnodata cneedupdate=N

  if [ "${pstatus}" == "Y" ]; then
    if ! getpulldetails "${item}" "${owner_repo_branch}" "${plast:-0}" >${pdata}; then
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

      [ ${DEBUG} == Y ] && echo "[${item}] Last known pull request #${plast}, current remote pull request #${pcrnt}"

      [ "${plast}" == "unknown" -a -n "${pcrnt}" ] && plast="${pcrnt}"

      if [ ${pnodata} == N ]; then
        echo "${pactual}" >${pdata}.actual
        output_pull_requests "${pdata}.actual" "${owner_repo_branch}" "${name}" > ${pitem}
        pneedupdate=Y
      fi
      [ ${pneedupdate} == Y ] && echo "${pcrnt}|${owner_repo_branch}|${name}" > ${pupdate}
    fi
  fi

  if [ "${cstatus}" == "Y" ]; then
    if ! getlatestsha "${item}" "${owner_repo_branch}" >${cdata}; then
      echo "ERROR: Failed to obtain current SHA for repository [${owner_repo_branch}]" >${cerror}
      return 1
    fi

    ccrnt="$(head -1 "${cdata}")"
    if [ -z "${ccrnt}" ]; then
      echo "${name}" >${cunavailable}
    else
      [ "${clast}" == "unknown" ] && cneedupdate=Y
      [ "${ccrnt}" == "${clast}" -o "${clast}" == "unknown" ] && cnodata=Y || cnodata=N

      [ ${DEBUG} == Y ] && echo "[${item}] Last known commit hash ${clast:0:7}, current remote commit hash ${ccrnt:0:7}"

      [ "${clast}" == "unknown" -a -n "${ccrnt}" ] && clast="${ccrnt}"

      if [ ${cnodata} == N ]; then
        if getcommitdetails "${item}" "${owner_repo_branch}" "${clast}" "${ccrnt}" >${cdata}.actual; then
          if [ -s ${cdata}.actual -a "$(cat ${cdata}.actual)" != "ERROR" ]; then
            output_commits "${cdata}.actual" "${owner_repo_branch}" "${name}" > ${citem}
            cneedupdate=Y
          fi
        else
          echo "ERROR: Failed to obtain commit comparison for repository [${owner_repo_branch}]" >${cerror}
          return 1
        fi
      fi
      [ ${cneedupdate} == Y ] && echo "${ccrnt}|${owner_repo_branch}|${name}" > ${cupdate}
    fi
  fi
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
    [ ${even} == Y ] && color="#f0f0f0" || color="#fcfcff"
    avatar="<img src=\"${avatar_url}\" style=\"height: 20px; width: 20px\" />"
    row="<tr style=\"background-color: ${color}; vertical-align: top\">"
    row="${row}<td style=\"padding-left: 10px; padding-right:10px; padding-top:2px\">${avatar}</td>"
    row="${row}<td style=\"padding-right: 10px; width: 100%\">${title}<br>"
    row="${row}<span style=\"font-size: 6pt; color: grey\">${committer//${FIELDSEP}/ }</span></td>"
    row="${row}</tr>"
    [ -n "${rows}" ] && rows="${rows}${NEWLINE}${row}" || rows="${row}"
    [ ${even} == Y ] && even=N || even=Y
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
    [ ${even} == Y ] && color="#f0f0f0" || color="#fcfcff"
    avatar="<img src=\"${avatar_url}\" style=\"height: 20px; width: 20px\" />"
    row="<tr style=\"background-color: ${color}; vertical-align: top\">"
    row="${row}<td style=\"padding-left: 10px; padding-right:10px; padding-top:2px\">${avatar}</td>"
    row="${row}<td style=\"padding-right: 10px; width: 100%\">${title}<br>"
    row="${row}<span style=\"font-size: 6pt; color: grey\">${committer//${FIELDSEP}/ }</span></td>"
    row="${row}</tr>"
    [ -n "${rows}" ] && rows="${rows}${NEWLINE}${row}" || rows="${row}"
    [ ${even} == Y ] && even=N || even=Y
  done < ${datafile}

  echo "${item//@@ITEM.ROWS@@/${rows}}"
}

get_processed_count()
{
  cd ${GHNOTIFY_WORKDIR}
  echo $(ls -1 * 2>/dev/null | cut -d. -f1 | sort -u | wc -l)
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
      while read -r newvalue owner_repo_branch name; do
        summary+=", ${name}"
        break
      done <<< "$(cat ${item}.*.update | sed 's/|/ /g')"
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
    if [ -f ${item}.pull.update -a -f ${item}.pull.item ]; then
      [ -n "${body}" ] && body+="${NEWLINE}"
      body+="$(cat ${item}.pull.item)"
    fi

    if [ -f ${item}.commit.update -a -f ${item}.commit.item ]; then
      [ -n "${body}" ] && body+="${NEWLINE}"
      body+="$(cat ${item}.commit.item)"
    fi
  done

  echo "${body}"
}

save_updated_details()
{
  local item newvalue owner_repo_branch name
  local target

  cd ${GHNOTIFY_WORKDIR}
  for item in $(ls -1 *.update 2>/dev/null | sort); do
    while read -r newvalue owner_repo_branch name; do
      break
    done <<< "$(cat ${item} | sed 's/|/ /g')"

    if [[ ${item} =~ .*\.pull\.update ]]; then
      target=${GHNOTIFY_PTEMP}
    elif [[ ${item} =~ .*\.commit\.update ]]; then
      target=${GHNOTIFY_CTEMP}
    fi

    sed -i "s${FIELDSEP}^${owner_repo_branch} .*\$${FIELDSEP}${owner_repo_branch} ${newvalue}${FIELDSEP}" ${target}
  done
}

process_work_items

if [ $(get_item_count) -ne 0 ]; then
  rm -fr ${TMPFILE}

  if [ ${NOEMAIL} == N ]; then
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

  if [ ${NOEMAIL} == N ]; then
    echo "${PAGE}" | qprint -be >> ${TMPFILE}
    cat ${TMPFILE} | ${BIN_MTA} || die 1 "ERROR: Failed to send email"
  else
    echo "${PAGE}" >> ${TMPFILE}
    mv ${TMPFILE} ${BIN}/email.html
  fi
fi

[ $(get_updated_count) -ne 0 ] && save_updated_details

if [ ${DEBUG} == N ]; then
  cp ${GHNOTIFY_PTEMP} ${GHNOTIFY_PDATA}
  cp ${GHNOTIFY_CTEMP} ${GHNOTIFY_CDATA}
fi

#rm -fr /tmp/gdata
#mv ${GHNOTIFY_WORKDIR} /tmp/gdata

exit 0
