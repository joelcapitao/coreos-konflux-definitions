#!/usr/bin/env bash

PR_START_TIME=$(date -u '+%s')

log() {
  echo "$@"
}

installAlpinePkgs() {
  sed -i -e 's/v3\.15/v3\.16/g' /etc/apk/repositories
  apk update
  apk add --upgrade apk-tools
  apk upgrade --available
  apk add skopeo jq grep curl libxml2-utils rsync
}

# shellcheck disable=SC2034
getEnvSecrets() {
  read -r TESTING_FARM_API_TOKEN < /etc/secrets/testing-farm-token
  export TESTING_FARM_API_TOKEN
}

# shellcheck disable=SC2034
getEnv() {
  APPLICATION=$(grep -oP '(?<=application=")[^"]+' </etc/podinfo/labels)
  PR_NAME=$(grep -oP '(?<=pipelineRun=")[^"]+' </etc/podinfo/labels)
  COMPONENT=$(grep -oP '(?<=component=")[^"]+' </etc/podinfo/labels)
  OPTIONAL=$(grep -oP '(?<=optional=")[^"]+' </etc/podinfo/labels)
  SCENARIO=$(grep -oP '(?<=scenario=")[^"]+' </etc/podinfo/labels)
  SNAPSHOT_NAME=$(grep -oP '(?<=snapshot=")[^"]+' </etc/podinfo/labels)
  LOG_URL=$(grep -oP '(?<=log-url=")[^"]+' </etc/podinfo/annotations)
  SHA_TITLE=$(grep -oP '(?<=sha-title=")[^"]+' </etc/podinfo/annotations)
  SHA_URL=$(grep -oP '(?<=sha-url=")[^"]+' </etc/podinfo/annotations)
  PR_START_TIME_STD=$(date -d "@$PR_START_TIME" -u '+%Y-%m-%dT%H:%M:%SZ')
  EVENT_TYPE=$(grep -oP '(?<=event-type=")[^"]+' </etc/podinfo/annotations)
  ONPUSH="true"
  [[ "$EVENT_TYPE" == [Pp]ush ]] || ONPUSH="false"
  SOURCE_URL=$(echo "${SNAPSHOT}" | jq -r ".components[]|select(.name==\"$COMPONENT\")|.source.git.url")
  SOURCE_REVISION=$(echo "${SNAPSHOT}" | jq -r ".components[]|select(.name==\"$COMPONENT\")|.source.git.revision")
  IMAGE=$(echo "${SNAPSHOT}" | jq -r ".components[]|select(.name==\"$COMPONENT\")|.containerImage")
  COUNT=$(echo "${SNAPSHOT}" | jq -r ".components|map(select(.name==\"$COMPONENT\"))|length")
  PR_LOG="${LOG_URL%/*}/${PR_NAME}/logs"
}

# shellcheck disable=SC2034
parseImage() {
  BOOTC_VARIANT=standard
  IMAGE_NAME=$(echo "${IMAGE##*/}" | cut -d @ -f 1)
  IMAGE_TAG=$(echo "${IMAGE##*/}" | cut -d : -f 2)
  COMMIT_ID=$(echo "$SHA_URL" | grep -oP '(?<=commit/)[[:alnum:]]+')
  ARCH="${TF_ARCHS-x86_64,aarch64,ppc64le,s390x}"
  TMT_TAG="${TMT_TAG-qemu}"
  COMPOSE="Fedora-43"
}

# shellcheck disable=SC2034
callTF() {
  BOOTC_TEMPDIR=$(mktemp -d -u)
  TF_COMMON_ARGV=(
    --tag ArtemisUseSpot=false
    --plan-filter "tag:${TMT_TAG}"
    --environment IMAGE_URL="${IMAGE}"
    --git-url "${GIT_URL}"
    --git-ref "${GIT_REF}"
    --compose "${COMPOSE}"
    --arch "${ARCH}"
    --timeout "240"
    --no-wait)
  log "Invoking testing-farm ${TF_COMMON_ARGV[*]}"
  testing-farm request \
    "${TF_COMMON_ARGV[@]}" | tee tf_stdout.txt

  R_ID=$(grep -oP "(?<=$TESTING_FARM_API_URL/requests/)[0-9a-z-]+" tf_stdout.txt)
  TF_ARTIFACTS_URL="$TESTING_FARM_API_URL/requests/${R_ID}"
}

waitForTFResult() {
  PREV_STATE="none"
  STATE="none"
  while true; do
    CUR_TIME=$(date -u '+%s')
    DURATION_MIN=$(((CUR_TIME - PR_START_TIME) / 60))
    if [[ $DURATION_MIN -gt $TIMEOUT ]]; then
      echo "Timeout! Failed to finish within \"${TIMEOUT}mins\"."
      break
    fi
    STATE=$(curl --retry 10 --retry-connrefused --connect-timeout 10 --retry-delay 30 -s "$TESTING_FARM_API_URL/requests/$R_ID" | jq -r '.state')
    if [ "$STATE" = "complete" ] || [ "$STATE" = "error" ]; then
      echo "Done! The current state is \"$STATE\"."
      break
    fi
    if [ "$STATE" != "$PREV_STATE" ]; then
      echo "The current state is \"$STATE\"."
      echo "Waiting for Testing Farm..."
    fi
    PREV_STATE="$STATE"
    sleep 90
  done
}

# shellcheck disable=SC2034
getTFQueueTime() {
  QUEUE_SECONDS=0
  INTERVAL=$1
  NOW_SEC=$(date -u "+%s")

  while [[ ${QUEUE_SECONDS%.*} -le 0 ]]; do
    PRE_SEC=$((NOW_SEC - INTERVAL))
    METRICS=$(curl -skL "${OSCI_METRICS_URL}" -H 'content-type: application/json' \
      -d "{\"queries\":[{\"datasource\":{\"type\":\"prometheus\"},\"expr\":\"rate(tf_requests_queued_time_seconds_sum{ranch=\\\"redhat\\\"}[\$__rate_interval]) / rate(tf_requests_queued_time_seconds_count{ranch=\\\"redhat\\\"}[\$__rate_interval])\n\",\"utcOffsetSec\":28800,\"datasourceId\":4,\"intervalMs\":15000,\"maxDataPoints\":1488}],\"from\":\"${PRE_SEC}000\",\"to\":\"${NOW_SEC}000\"}")
    QUEUE_SECONDS=$(echo "${METRICS}" | jq -r '[.results.A.frames[0].data.values[1][] // 0]|add/length*100|round/100')
    QUEUE_SECONDS_INT=${QUEUE_SECONDS%.*}
    INTERVAL=$((INTERVAL * 2))
  done
}
