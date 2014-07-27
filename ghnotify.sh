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
VERSION="v0.0.2"

BIN=$(readlink -f $(dirname $0))

# Stop sending emails if the specified number of days have elapsed since
# the last modification to the CHECK_FILE.
CHECK_INTERVAL_DAYS=14
CHECK_FILE=${BIN}/patches.dat

#Try and find a usable mail transfer agent (MTA).
#
# A list of possible MTA clients is tested, and when multiple MTA clients are
# present the last one will be used, so order them in ascending (left-to-right)
# order of priority.
#
# msmtp_safe is a personalised wrapper for msmpt that will retry transmission
# up to 10 times in the event of msmpt timing out.
#
for emailclient in sendmail ssmtp msmtp msmtp_safe; do
  command -v ${emailclient} 2>&1 >/dev/null && BIN_MTA="$(command -v ${emailclient})"
done

GITAPI="https://api.github.com/repos"
FCONF=${BIN}/ghnotify.conf
FDATA=${BIN}/ghnotify.dat
FDATA_TMP=${BIN}/ghnotify.dat.tmp

HTML_TEMPLATE_MAIN=${BIN}/ghnotify.template.main
HTML_TEMPLATE_SUB=${BIN}/ghnotify.template.sub

FIELDSEP=$'\001'
NEWLINE=$'\012'

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

[ "$1" == "debug" ] && DEBUG=Y || DEBUG=N

[ -f ~/.git.conf ] && source ~/.git.conf
[ -n "${GIT_USERNAME}" -a -n "${GIT_PASSWORD}" ] && AUTHENTICATION="-u ${GIT_USERNAME}:${GIT_PASSWORD}"

[ ! -f ${FCONF} ]              && die 1 "Cannot find configuration file [${FCONF}]"
[ ! -f ${HTML_TEMPLATE_MAIN} ] && die 1 "Cannot find primary template file [${HTML_TEMPLATE_MAIN}]"
[ ! -f ${HTML_TEMPLATE_SUB} ]  && die 1 "Cannot find secondary template file [${HTML_TEMPLATE_SUB}]"
[ ! -x ${BIN_MTA} ]            && die 1 "Email client not found [${BIN_MTA}]"

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

  echo "${RESPONSE}" | python -c '
import sys, json, datetime

def whendelta(when):
  dt = datetime.datetime.now() - datetime.datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ")
  if dt.days > 0:
    return "%s day%s ago" % (dt.days, "s"[dt.days==1:])
  hours = dt.seconds / 3600
  if hours > 0:
    return "%s hour%s ago" % (hours, "s"[hours==1:])
  mins = dt.seconds / 60
  return "%s minute%s ago" % (mins, "s"[mins==1:])

data=[]
for line in sys.stdin: data.append(line)
jdata = json.loads("".join(data))
if "commits" in jdata:
  try:
    for c in reversed(jdata["commits"]):
      if c["author"]:
        avatar_url = "%ss=20" % c["author"]["avatar_url"]
        author = c["author"]["login"]
      else:
        avatar_url = "https://i2.wp.com/assets-cdn.github.com/images/gravatars/gravatar-user-420.png?ssl=1&s=20"
        author = c["commit"]["author"]["name"]

      commitdata = "%s authored %s" % (author, whendelta(c["commit"]["author"]["date"]))
      
      if c["committer"] and c["committer"]["login"] != author:
        commitdata = "%s (%s committed %s)" % (commitdata, c["committer"]["login"], whendelta(c["commit"]["committer"]["date"]))

      message = c["commit"]["message"].split("\n")[0]
      print("%s %s %s" % (avatar_url, commitdata.replace(" ", "\001"), message))
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

#Stop reporting new commits if there has been no build activity during the specified period
if [ -f ${CHECK_FILE} -a ${CHECK_INTERVAL_DAYS} -ne 0 ]; then
  DELTA=$(($(date +%s) - $(stat -c%Y ${CHECK_FILE})))
  [ ${DELTA} -ge $((${CHECK_INTERVAL_DAYS} * 24 * 60 * 60)) ] && die 0 "Exceeded check interval ${CHECK_INTERVAL_DAYS} days"
fi

[ ! -f ${FDATA} ] && touch ${FDATA}
cp ${FDATA} ${FDATA_TMP} 

BODY=
PROCESSED=0
UNAVAILABLE=0
UNAV_NAME=
while read -r OWNER_REPO_BRANCH NAME; do
  printf "Processing: %-35s" "${NAME}... "
  PROCESSED=$((PROCESSED+1))

  CRNT="$(getlatestsha ${OWNER_REPO_BRANCH})" || die 1 "Failed to obtain current SHA for repository [${OWNER_REPO_BRANCH}]"
  [ -z "${CRNT}" ] && echo "UNAVAILABLE" && UNAVAILABLE=$((UNAVAILABLE+1)) && UNAV_NAME="${UNAV_NAME}${FIELDSEP}${NAME}" && continue

  LAST="$(grep "^${OWNER_REPO_BRANCH}" ${FDATA_TMP} | tail -1 | awk '{ print $2 }')"

  [ -z "${LAST}" ] && echo "${OWNER_REPO_BRANCH} ${CRNT}" >> ${FDATA_TMP}
  [ "${CRNT}" == "${LAST}" -o -z "${LAST}" ] && echo "No new commits" && continue

  COMMITS="$(getcommitdetails "${OWNER_REPO_BRANCH}" "${LAST}" "${CRNT}")" || die 1 "Failed to obtain commit comparison for repository [${OWNER_REPO_BRANCH}]"
  sed -i "s${FIELDSEP}^${OWNER_REPO_BRANCH} ${LAST}${FIELDSEP}${OWNER_REPO_BRANCH} ${CRNT}${FIELDSEP}" ${FDATA_TMP}
  [ -z "${COMMITS}" ] && echo "No new commits" && continue || echo "$(echo "${COMMITS}" | wc -l) new commits"

  URL="$(getcommitsurl "${OWNER_REPO_BRANCH}")"

  ITEM="$(cat ${HTML_TEMPLATE_SUB})"
  ITEM="${ITEM//@@ITEM.URL@@/${URL}}"
  ITEM="${ITEM//@@ITEM.SUBJECT@@/${NAME}}"
  ROWS=
  EVEN=Y
  while read -r avatar_url committer title; do
    [ $EVEN == Y ] && COLOR="#f0f0f0" || COLOR="#fcfcff"
    avatar="<img src=\"${avatar_url}\" style=\"height: 20px; width: 20px\" />"
    title="${title//</&lt;}"
    title="${title//>/&gt;}"
    committer="${committer//${FIELDSEP}/ }"
    ROW="<tr style=\"background-color: ${COLOR}; vertical-align: top\">"
    ROW="${ROW}<td style=\"padding-left: 10px; padding-right:10px; padding-top:2px\">${avatar}</td>"
    ROW="${ROW}<td style=\"padding-right: 10px; width: 100%\">${title}<br/><span style=\"font-size: 6pt; color: grey\">${committer}</span></td>"
    ROW="${ROW}</tr>"
    [ -n "${ROWS}" ] && ROWS="${ROWS}${NEWLINE}${ROW}" || ROWS="${ROW}"
    [ $EVEN == Y ] && EVEN=N || EVEN=Y
  done <<< "${COMMITS}"

  ITEM="${ITEM//@@ITEM.ROWS@@/${ROWS}}"
  [ -n "${BODY}" ] && BODY="${BODY}${NEWLINE}${ITEM}" || BODY="${ITEM}"
done <<< "$(grep -v "^#" ${FCONF})"

if [ -n "${BODY}" ]; then
  TMPFILE=$(mktemp)
  rm -fr ${TMPFILE}

  if [ ${DEBUG} == N ]; then
    echo "To: ${EMAILTO}" >> ${TMPFILE}
    echo "Subject: New GitHub Commits" >> ${TMPFILE}
    echo "Content-Type: text/html; charset=utf-8" >> ${TMPFILE}
    echo "Content-Transfer-Encoding: quoted-printable" >>${TMPFILE}
  fi

  STATUS="Processed: ${PROCESSED}, Unavailable: ${UNAVAILABLE}"
  [ -n "${UNAV_NAME}" ] &&  STATUS="${STATUS}<span>${UNAV_NAME//${FIELDSEP}/</span></br>${NEWLINE}Unavailable: <span style=\"color:red\">}</span>"

  PAGE="$(cat ${HTML_TEMPLATE_MAIN})"
  PAGE="${PAGE//@@BODY.DETAIL@@/${BODY}}"
  PAGE="${PAGE//@@SCRIPT.STATUS@@/${STATUS}}"
  PAGE="${PAGE//@@SCRIPT.VERSION@@/${VERSION}}"

  if [ ${DEBUG} == N ]; then
    echo "${PAGE}" | qprint -be >> ${TMPFILE}
    cat ${TMPFILE} | ${BIN_MTA} && mv ${FDATA_TMP} ${FDATA} 
  else
    echo "${PAGE}" >> ${TMPFILE}
    mv ${TMPFILE} ${BIN}/email.html
  fi

  rm -f ${TMPFILE}
fi

rm -f ${FDATA_TMP}

exit 0
