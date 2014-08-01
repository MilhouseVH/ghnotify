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
# Writes the latest SHA of each monitored repository to ./ghnotify.dat.
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
# (c) Neil MacLeod 2014 :: ghnotify@nmacleod.com :: https://github.com/MilhouseVH/ghnotify
#
VERSION="v0.0.8"

BIN=$(readlink -f $(dirname $0))

# Stop sending emails if the specified number of days have elapsed since
# the last modification to the CHECK_FILE.
CHECK_INTERVAL_DAYS=14
CHECK_FILE=${BIN}/patches.dat

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
  echo "$(echo "$2" | awk -F"/" -vF=$1 '{print $F}')"
}

getlatestsha()
{
  URL="${GITAPI}/$(getcomponent 1 "$1")/$(getcomponent 2 "$1")/commits?per_page=1&sha=$(getcomponent 3 "$1")"
  RESPONSE="$(curl -s ${AUTHENTICATION} --connect-timeout 30 ${URL})" || return 1

  echo "${RESPONSE}" | python -c '
import sys, json
data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))
for item in jdata:
  if "sha" in item:
    print("%s" % item["sha"][:7])
  break
'
  return 0
}

getcommitdetails()
{
  URL="${GITAPI}/$(getcomponent 1 "$1")/$(getcomponent 2 "$1")/compare/$2...$3"
  RESPONSE="$(curl -s ${AUTHENTICATION} --connect-timeout 30 ${URL})" || return 1
  [ "${DEBUG}" = Y ] && echo "${RESPONSE}" >${BIN}/dbg_$(echo "$1"|sed "s#/#_#g")

  echo "${RESPONSE}" | python -c '
import os, sys, json, datetime, urllib2, codecs

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
    sys.stderr.write("%s\n" % msg)

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

data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))
if "commits" in jdata:
  debug("\n%d commits loaded for %s" % (len(jdata["commits"]), jdata["url"]))
  try:
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

      message = c["commit"]["message"].split("\n")[0]
      print("%s %s %s" % (avatar_url, commitdata.replace(" ", "\001"), message))

      debug("  Message : %s" % message)
      debug("  Avatar  : %s" % avatar_url)
      debug("  Who/When: %s" % commitdata)

  except:
    raise
    sys.exit(1)
'
  return $?
}

getcommitsurl()
{
  echo "https://github.com/$(getcomponent 1 "$1")/$(getcomponent 2 "$1")/commits/$(getcomponent 3 "$1")"
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
  <title>New GitHub Commits</title>
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
        <div style="color: #176093; text-decoration:none">New GitHub Commits</div>
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
        <h2 style="font-size: 15pt; font-weight: normal; margin: 10px 10px 0 10px"><a href="@@ITEM.URL@@" style="color: #176093; text-decoration: none">@@ITEM.SUBJECT@@</a></h2>
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
GHNOTIFY_TEMP=/tmp/ghnotify.dat.tmp

NOEMAIL=N
for arg in $@; do
  case "${arg}" in
    debug)   NOEMAIL=Y; export DEBUG=Y;;
    noemail) NOEMAIL=Y;;
  esac
done

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
[ -f ~/${GHNOTIFY_CONF} ] && GHNOTIFY_CONF=~/${GHNOTIFY_CONF} || GHNOTIFY_CONF="${BIN}/${GHNOTIFY_CONF}"
[ -f ~/${GHNOTIFY_DATA} ] && GHNOTIFY_DATA=~/${GHNOTIFY_DATA} || GHNOTIFY_DATA="${BIN}/${GHNOTIFY_DATA}"

# Optionally load GIT authentication and override settings, eg. EMAILTO, GHNOTIFY_DATA etc.
[ -f ~/.git.conf ] && source ~/.git.conf

[ -n "${GIT_USERNAME}" -a -n "${GIT_PASSWORD}" ] && AUTHENTICATION="-u ${GIT_USERNAME}:${GIT_PASSWORD}"

[ ! -f ${GHNOTIFY_CONF} ] && die 1 "Cannot find configuration file [${GHNOTIFY_CONF}]"
[ ! -x ${BIN_MTA} ]       && die 1 "Email client not found [${BIN_MTA}]"

#Stop reporting new commits if there has been no build activity for longer than the specified period
if [ -f ${CHECK_FILE} -a ${CHECK_INTERVAL_DAYS} -ne 0 ]; then
  DELTA=$(($(date +%s) - $(stat -c%Y ${CHECK_FILE})))
  [ ${DELTA} -ge $((${CHECK_INTERVAL_DAYS} * 24 * 60 * 60)) ] && die 0 "Exceeded check interval ${CHECK_INTERVAL_DAYS} days"
fi

[ ! -f ${GHNOTIFY_DATA} ] && touch ${GHNOTIFY_DATA}
cp ${GHNOTIFY_DATA} ${GHNOTIFY_TEMP}

BODY=
PROCESSED=0
UNAVAILABLE=0
UNAVAILABLE_ITEMS=
while read -r OWNER_REPO_BRANCH NAME; do
  printf "Processing: %-35s" "${NAME}... "
  PROCESSED=$((PROCESSED+1))

  CRNT="$(getlatestsha ${OWNER_REPO_BRANCH})" || die 1 "Failed to obtain current SHA for repository [${OWNER_REPO_BRANCH}]"
  [ -z "${CRNT}" ] && echo "UNAVAILABLE" && UNAVAILABLE=$((UNAVAILABLE+1)) && UNAVAILABLE_ITEMS="${UNAVAILABLE_ITEMS}${FIELDSEP}${NAME}" && continue

  LAST="$(grep "^${OWNER_REPO_BRANCH}" ${GHNOTIFY_TEMP} | tail -1 | awk '{ print $2 }')"

  [ -z "${LAST}" ] && echo "${OWNER_REPO_BRANCH} ${CRNT}" >> ${GHNOTIFY_TEMP}
  [ "${CRNT}" == "${LAST}" -o -z "${LAST}" ] && echo "No new commits" && continue

  COMMITS="$(getcommitdetails "${OWNER_REPO_BRANCH}" "${LAST}" "${CRNT}")" || die 1 "Failed to obtain commit comparison for repository [${OWNER_REPO_BRANCH}]"
  sed -i "s${FIELDSEP}^${OWNER_REPO_BRANCH} ${LAST}${FIELDSEP}${OWNER_REPO_BRANCH} ${CRNT}${FIELDSEP}" ${GHNOTIFY_TEMP}
  [ -z "${COMMITS}" ] && echo "No new commits" && continue || echo "$(echo "${COMMITS}" | wc -l) new commits"

  URL="$(getcommitsurl "${OWNER_REPO_BRANCH}")"

  ITEM="${HTML_SUB}"
  ITEM="${ITEM//@@ITEM.URL@@/${URL}}"
  ITEM="${ITEM//@@ITEM.SUBJECT@@/$(htmlsafe "${NAME}")}"
  ROWS=
  EVEN=Y
  while read -r avatar_url committer title; do
    [ $EVEN == Y ] && COLOR="#f0f0f0" || COLOR="#fcfcff"
    avatar="<img src=\"${avatar_url}\" style=\"height: 20px; width: 20px\" />"
    ROW="<tr style=\"background-color: ${COLOR}; vertical-align: top\">"
    ROW="${ROW}<td style=\"padding-left: 10px; padding-right:10px; padding-top:2px\">${avatar}</td>"
    ROW="${ROW}<td style=\"padding-right: 10px; width: 100%\">$(htmlsafe "${title}")<br>"
    ROW="${ROW}<span style=\"font-size: 6pt; color: grey\">$(htmlsafe "${committer//${FIELDSEP}/ }")</span></td>"
    ROW="${ROW}</tr>"
    [ -n "${ROWS}" ] && ROWS="${ROWS}${NEWLINE}${ROW}" || ROWS="${ROW}"
    [ $EVEN == Y ] && EVEN=N || EVEN=Y
  done <<< "${COMMITS}"

  ITEM="${ITEM//@@ITEM.ROWS@@/${ROWS}}"
  [ -n "${BODY}" ] && BODY="${BODY}${NEWLINE}${ITEM}" || BODY="${ITEM}"
done <<< "$(grep -v "^#" ${GHNOTIFY_CONF})"

if [ -n "${BODY}" ]; then
  TMPFILE=$(mktemp)
  rm -fr ${TMPFILE}

  if [ ${NOEMAIL} == N ]; then
    echo "To: ${EMAILTO}" >> ${TMPFILE}
    echo "Subject: New GitHub Commits" >> ${TMPFILE}
    echo "Content-Type: text/html; charset=utf-8" >> ${TMPFILE}
    echo "Content-Transfer-Encoding: quoted-printable" >>${TMPFILE}
  fi

  STATUS="Processed: ${PROCESSED}, Unavailable: ${UNAVAILABLE}"
  UNAVAILABLE_ITEMS="$(htmlsafe "${UNAVAILABLE_ITEMS}")"
  [ -n "${UNAVAILABLE_ITEMS}" ] &&  STATUS="${STATUS}<span>${UNAVAILABLE_ITEMS//${FIELDSEP}/</span><br>${NEWLINE}Unavailable: <span style=\"color:red\">}</span>"

  PAGE="${HTML_MAIN}"
  PAGE="${PAGE//@@BODY.DETAIL@@/${BODY}}"
  PAGE="${PAGE//@@SCRIPT.STATUS@@/${STATUS}}"
  PAGE="${PAGE//@@SCRIPT.VERSION@@/${VERSION}}"

  if [ ${NOEMAIL} == N ]; then
    echo "${PAGE}" | qprint -be >> ${TMPFILE}
    cat ${TMPFILE} | ${BIN_MTA} && mv ${GHNOTIFY_TEMP} ${GHNOTIFY_DATA}
  else
    echo "${PAGE}" >> ${TMPFILE}
    mv ${TMPFILE} ${BIN}/email.html
  fi

  rm -f ${TMPFILE}
fi

rm -f ${GHNOTIFY_TEMP}

exit 0
