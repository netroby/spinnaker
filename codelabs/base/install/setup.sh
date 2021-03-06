#!/usr/bin/env bash

bold() {
  echo ". $(tput bold)" "$*" "$(tput sgr0)";
}

err() {
  echo "$*" >&2;
}

source ./properties

if [ -z "$PROJECT_ID" ]; then
  err "Not running in a GCP project. Exiting."
  exit 1
fi

bold "Starting the setup process in project $PROJECT_ID..."

bold "Creating a service account $SERVICE_ACCOUNT_NAME..."

gcloud iam service-accounts create \
  $SERVICE_ACCOUNT_NAME \
  --display-name $SERVICE_ACCOUNT_NAME

SA_EMAIL=$(gcloud iam service-accounts list \
  --filter="displayName:$SERVICE_ACCOUNT_NAME" \
  --format='value(email)')

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member serviceAccount:$SA_EMAIL \
  --role roles/owner

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member serviceAccount:$SA_EMAIL \
  --role roles/pubsub.subscriber

bold "Using bucket $BUCKET_URI..."

gsutil mb $BUCKET_URI

bold "Installing the 'spin' CLI..."

curl -LO https://storage.googleapis.com/spinnaker-artifacts/spin/$(curl -s https://storage.googleapis.com/spinnaker-artifacts/spin/latest)/linux/amd64/spin

chmod +x spin

mkdir bin/

mv spin bin/

export PATH=$PATH:`pwd`/bin

replace() {
  sed -i $1 manifests.yml
}

replace 's|{%SPIN_GCS_ACCOUNT%}|'$SPIN_GCS_ACCOUNT'|g'
replace 's|{%SPIN_GCS_PUB_SUB%}|'$SPIN_GCS_PUB_SUB'|g'
replace 's|{%GCS_SUB%}|'$GCS_SUB'|g'
replace 's|{%GCR_SUB%}|'$GCR_SUB'|g'
replace 's|{%SPIN_GCR_PUB_SUB%}|'$SPIN_GCR_PUB_SUB'|g'
replace 's|{%PROJECT_ID%}|'$PROJECT_ID'|g'
replace 's|{%BUCKET_URI%}|'$BUCKET_URI'|g'
replace 's|{%BUCKET_NAME%}|'$BUCKET_NAME'|g'

bold "Configuring pub/sub from $GCS_TOPIC -> $GCS_SUB..."

gsutil notification create -t $GCS_TOPIC -f json $BUCKET_URI
gcloud pubsub subscriptions create $GCS_SUB --topic $GCS_TOPIC

bold "Configuring pub/sub for our docker builds..."

gcloud pubsub topics create projects/${PROJECT_ID}/topics/gcr
gcloud beta pubsub subscriptions create $GCR_SUB --topic $GCR_TOPIC

bold "Creating your cluster $GKE_CLUSTER..."

gcloud container clusters create $GKE_CLUSTER --zone $ZONE \
  --service-account $SA_EMAIL \
  --username admin --cluster-version 1.8.8-gke.0 \
  --machine-type n1-standard-4 --image-type COS --disk-size 100 \
  --num-nodes 3 --enable-cloud-logging --enable-cloud-monitoring

gcloud container clusters get-credentials $GKE_CLUSTER --zone $ZONE

bold "Deploying spinnaker..."

kubectl apply -f manifests.yml

bold "Waiting for spinnaker setup to complete (this might take some time)..."

job_ready() {
  kubectl get job $1 -n spinnaker -o jsonpath="{.status.succeeded}"
}

printf "Waiting on deployment to finish"
while [[ "$(job_ready hal-deploy-apply)" != "1" ]]; do
  printf "."
  sleep 5
done
echo ""

deploy_ready() {
  kubectl get deploy $1 -n spinnaker -o jsonpath="{.status.readyReplicas}"
}

printf "Waiting on API server to come online"
while [[ "$(deploy_ready spin-gate)" != "1" ]]; do
  printf "."
  sleep 5
done
echo ""

printf "Waiting on storage server to come online"
while [[ "$(deploy_ready spin-front50)" != "1" ]]; do
  printf "."
  sleep 5
done
echo ""

printf "Waiting on orchestration engine to come online"
while [[ "$(deploy_ready spin-orca)" != "1" ]]; do
  printf "."
  sleep 5
done
echo ""

bold "Ready! Run ./connect.sh to continue..."
