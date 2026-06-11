#!/bin/bash
set -e

HOST_GCLOUD="/home/podman/.config/gcloud-host"
LOCAL_GCLOUD="/home/podman/.config/gcloud"
ADC_FILE="application_default_credentials.json"
QUOTA_PROJECT="${GCLOUD_QUOTA_PROJECT:-}"

if [ -d "$HOST_GCLOUD" ]; then
    echo "ホストのgcloud設定をコピーしています..."
    cp -r "$HOST_GCLOUD" "$LOCAL_GCLOUD"

    if [ -n "$QUOTA_PROJECT" ] && [ -f "$LOCAL_GCLOUD/$ADC_FILE" ]; then
        jq --arg qp "$QUOTA_PROJECT" '. + {quota_project_id: $qp}' \
            "$LOCAL_GCLOUD/$ADC_FILE" > /tmp/adc_tmp.json \
            && mv /tmp/adc_tmp.json "$LOCAL_GCLOUD/$ADC_FILE"
        echo "ADC quota project を $QUOTA_PROJECT に設定しました"
    fi

    echo "gcloud設定のセットアップ完了"
else
    echo "====================================="
    echo "ホストのgcloud設定が見つかりません。"
    echo "手動で以下を実行してください："
    echo "  gcloud init"
    echo "  gcloud auth application-default login"
    echo "  gcloud auth application-default set-quota-project <your-quota-project>"
    echo "====================================="
fi
