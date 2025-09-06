#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

TMPDIR=$(mktemp -d)
cp * $TMPDIR/
pushd $TMPDIR

[ -z "${SMEE_WEBHOOK_SECRET}" ] && echo "SMEE_WEBHOOK_SECRET should be set" && exit 1
[ -z "${QUAY_KONFLUX_APP_TOKEN}" ] && echo "QUAY_KONFLUX_APP_TOKEN should be set" && exit 1
#[ -z "${GITLAB_ACCESS_TOKEN}" ] && echo "GITLAB_ACCESS_TOKEN should be set" && exit 1
#[ -z "${TESTING_FARM_API_TOKEN}" ] && echo "TESTING_FARM_API_TOKEN should be set" && exit 1
# The namespace is defined in cluster setup instructions https://github.com/konflux-ci/konflux-ci/blob/main/README.md#create-application-and-component-via-the-konflux-ui
NAMESPACE=${NAMESPACE:-user-ns2}
PIPELINE_NAME=${PIPELINE_NAME:-testing-farm-container}
KIND_VERSION=${KIND_VERSION:-0.25.0}
TEKTON_CLI_VERSION=${TEKTON_CLI_VERSION:-0.39.0}

rlJournalStart
  # Setup cluster according to https://github.com/konflux-ci/konflux-ci/blob/main/README.md#trying-out-konflux
  rlPhaseStartSetup "Install kubectl"
    rlRun "curl -LO \"https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\"" 0 "Install kubectl"
    rlRun "install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
  rlPhaseEnd

  rlPhaseStartSetup "Install kind"
    rlRun "curl -Lo ./kind https://kind.sigs.k8s.io/dl/v$KIND_VERSION/kind-linux-amd64" 0 "Install kind"
    rlRun "chmod +x ./kind"
    rlRun "sudo mv ./kind /usr/local/bin/kind"
  rlPhaseEnd

  rlPhaseStartSetup "Install tkn"
    rlRun "rpm -Uvh https://github.com/tektoncd/cli/releases/download/v$TEKTON_CLI_VERSION/tektoncd-cli-${TEKTON_CLI_VERSION}_Linux-64bit.rpm" 0 "Install tkn"
  rlPhaseEnd

  rlPhaseStartSetup "Deploy cluster"
    # Note: It is recommended that you increase the inotify resource limits in order to avoid issues related to too many open files. To increase the limits temporarily, run the following commands:
    rlRun "sysctl fs.inotify.max_user_watches=524288"
    rlRun "sysctl fs.inotify.max_user_instances=512"

    rlRun "git clone https://github.com/konflux-ci/konflux-ci.git" 0 "Clone konflux-ci"
    rlRun "pushd konflux-ci"

    rlRun "kind create cluster --name konflux --config kind-config.yaml" 0 "Create kind cluster"

    rlRun "./deploy-deps.sh" 0 "Deploy dependencies"

    rlRun "./deploy-konflux.sh" 0 "Deploy konflux-ci"

    rlRun "./deploy-test-resources.sh" 0 "Deploy demo users"

    rlRun "./deploy-image-controller.sh $QUAY_KONFLUX_APP_TOKEN coreos-konflux-jcapitao" 0 "Deploy image controller"

    rlRun "curl -kL https://localhost:9443" 0 "Verify konflux-ci is up"
    rlRun "popd"
  rlPhaseEnd

  rlPhaseStartSetup "Setup cluster"

    #rlRun "kubectl -n $NAMESPACE create secret generic gitlab-webhook-config --from-literal provider.token=\"$GITLAB_ACCESS_TOKEN\" --from-literal webhook.secret=\"$SMEE_WEBHOOK_SECRET\"" 0 "Create gitlab webhook secret"
    #rlRun "kubectl -n $NAMESPACE create secret generic testing-farm-secret --from-literal testing-farm-token=\"$TESTING_FARM_API_TOKEN\"" 0 "Create TF API token secret" 0 "Create TF API token secret"

    rlRun "kubectl delete deployment gosmee-client -n smee-client" 0-255 "Delete smee-client deployment"
    rlRun "kubectl delete namespace smee-client" 0-255 "Delete smee-client namespace"

    rlRun "kubectl create -f ./smee-client.yaml" 0 "Deploy smee-client"

    rlRun "kubectl create -f ./application-and-component.yaml" 0 "Create application and component"

    rlRun "kubectl create -f ./integration-tests.yaml" 0 "Create integration tests"

    rlRun "while ! kubectl describe deployment -n smee-client | grep -q \"1 available\"; do echo \"Waiting for smee client deployment to spin up\" ;sleep 1; done" 0 "Wait for smee client deployment to spin up"

  rlPhaseEnd

  rlPhaseStartSetup "Create MR"

    rlRun "glab auth login -t $GITLAB_ACCESS_TOKEN" 0 "Login to gitlab"
    rlRun "glab mr note -R https://gitlab.com/testing-farm/integrations/tekton-testrepo.git 1 -m '/retest'" 0 "Comment in MR"

  rlPhaseEnd

  rlPhaseStartSetup "Wait for pipeline run to appear"

    rlRun "timeout 600 bash -c -- \"while ! tkn -n $NAMESPACE pipelinerun list | grep $PIPELINE_NAME >/dev/null 2>&1; do echo 'Waiting for pipeline run to appear'; sleep 10; done\"" 0 "Wait for pipeline run to appear"
    rlRun "tkn -n $NAMESPACE pipelinerun list" 0 "List pipeline runs"

    rlRun "TEST_ID=$(tkn -n $NAMESPACE pipelinerun list | grep $PIPELINE_NAME | awk '{ print $1 }')" 0 "Get pipeline run id"
    rlLog "Test ID is $TEST_ID"

    rlRun "tkn -n $NAMESPACE pipelinerun describe $TEST_ID" 0 "Describe pipeline run for debug purposes"

    function update_status() {
        STATUS=$(tkn -n $NAMESPACE pipelinerun describe $TEST_ID --output json | jq -r ".status.conditions[].reason")
        echo "$STATUS";
    }

    rlRun update_status 0 "Update status"
    rlRun "while true; do STATUS=\$(update_status); echo \"Status is \$STATUS\"; case \"\$STATUS\" in Succeeded|Failed|Completed) break; esac; sleep 5; done" 0 "Wait for pipeline run to finish"

  rlPhaseEnd

  rlPhaseStartTest

    rlRun "tkn -n $NAMESPACE pipelinerun describe $TEST_ID" 0 "Describe pipeline run for debug purposes"
    rlRun "tkn -n $NAMESPACE pipelinerun logs $TEST_ID" 0 "Show pipeline run logs"


    if [[ "$STATUS" == "Failed" ]]; then
      rlLog "Test Failed"
      rlFail
    fi
    rlPass

  rlPhaseEnd

rlJournalPrintText
rlJournalEnd

