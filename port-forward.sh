#!/bin/bash

if [[ -f "/usr/share/bin/kind" ]]; then
  if (! (kind get clusters | grep "No kind clusters found")); then
    if (! ppgrep -f -a 'kubectl port-forward'); then
      echo ""
      echo "There is a KIND cluster running"
      echo "As a workaround, K8s port-fording is started with the following command:"
      echo ""
      echo "	sudo kubectl port-forward -n korifi --address ::1 svc/korifi-api-svc 443:443 &"
      echo ""
      sudo kubectl port-forward -n korifi --address ::1 svc/korifi-api-svc 443:443 &
    else
      echo "KIND running and portforwarding found"
    fi
  else
    echo "No KIND running"
  fi
else
  echo "KIND not installed"
fi
