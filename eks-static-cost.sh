#!/usr/bin/env bash
set -euo pipefail

############################################
# LOAD ENV
############################################
if [[ ! -f .env ]]; then
  echo "❌ .env file not found"
  exit 1
fi

set -o allexport
source .env
set +o allexport

############################################
# VALIDATION
############################################
required_vars=(
  CLUSTER_NAME
  AWS_PROFILE
  AWS_REGION
  HOURS_PER_MONTH
  EKS_CONTROL_PLANE_HOURLY
  EBS_GP3_PER_GB_MONTH
  NAT_GATEWAY_HOURLY
  ALB_HOURLY
  NLB_HOURLY
)

for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "❌ Missing required variable: $v"
    exit 1
  fi
done

############################################
# EC2 PRICES MAP
############################################
declare -A EC2_PRICES=(
  ["t3.medium"]="$EC2_T3_MEDIUM"
  ["t3.large"]="$EC2_T3_LARGE"
  ["m5.large"]="$EC2_M5_LARGE"
  ["m5.xlarge"]="$EC2_M5_XLARGE"
)

############################################
# HELPERS
############################################
monthly() {
  awk "BEGIN { printf \"%.2f\", $1 * $HOURS_PER_MONTH }"
}

line() {
  printf "%-40s %10s\n" "$1" "$2"
}

aws_cli() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"
}

total=0

echo "🔍 Calculating static monthly cost for EKS cluster: $CLUSTER_NAME"
echo "AWS profile: $AWS_PROFILE"
echo "Region: $AWS_REGION"
echo "------------------------------------------------------------"

############################################
# EKS CONTROL PLANE
############################################
eks_monthly=$(monthly "$EKS_CONTROL_PLANE_HOURLY")
line "EKS control plane" "£$eks_monthly"
total=$(awk "BEGIN { print $total + $eks_monthly }")

############################################
# EC2 WORKER NODES
############################################
echo
echo "🖥 EC2 worker nodes"

instances=$(aws_cli ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
  --query "Reservations[].Instances[].InstanceType" \
  --output text)

declare -A COUNTS

for i in $instances; do
  COUNTS[$i]=$(( ${COUNTS[$i]:-0} + 1 ))
done

for type in "${!COUNTS[@]}"; do
  count=${COUNTS[$type]}
  price=${EC2_PRICES[$type]:-}

  if [[ -z "$price" ]]; then
    echo "⚠️  No price configured for instance type $type (skipping)"
    continue
  fi

  monthly_cost=$(monthly "$(awk "BEGIN { print $price * $count }")")
  line "$count × $type" "£$monthly_cost"
  total=$(awk "BEGIN { print $total + $monthly_cost }")
done

############################################
# EBS VOLUMES
############################################
echo
echo "💾 EBS volumes"

ebs_gb=$(aws_cli ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
  --query "Volumes[].Size" \
  --output text | awk '{sum+=$1} END {print sum+0}')

ebs_monthly=$(awk "BEGIN { printf \"%.2f\", $ebs_gb * $EBS_GP3_PER_GB_MONTH }")
line "EBS gp3 ($ebs_gb GB)" "£$ebs_monthly"
total=$(awk "BEGIN { print $total + $ebs_monthly }")

############################################
# NAT GATEWAYS
############################################
echo
echo "🌐 NAT gateways"

nat_count=$(aws_cli ec2 describe-nat-gateways \
  --filter "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
  --query "NatGateways[].NatGatewayId" \
  --output text | wc -w)

if [[ "$nat_count" -gt 0 ]]; then
  nat_monthly=$(monthly "$(awk "BEGIN { print $NAT_GATEWAY_HOURLY * $nat_count }")")
  line "$nat_count × NAT Gateway" "£$nat_monthly"
  total=$(awk "BEGIN { print $total + $nat_monthly }")
else
  line "NAT Gateways" "£0.00"
fi

############################################
# LOAD BALANCERS
############################################
echo
echo "⚖ Load balancers"

alb_count=0
nlb_count=0

lbs=$(aws_cli elbv2 describe-load-balancers \
  --query "LoadBalancers[].LoadBalancerArn" \
  --output text)

for lb in $lbs; do
  tagged=$(aws_cli elbv2 describe-tags \
    --resource-arns "$lb" \
    --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME']" \
    --output text)

  if [[ -n "$tagged" ]]; then
    type=$(aws_cli elbv2 describe-load-balancers \
      --load-balancer-arns "$lb" \
      --query "LoadBalancers[].Type" \
      --output text)

    [[ "$type" == "application" ]] && alb_count=$((alb_count+1))
    [[ "$type" == "network" ]] && nlb_count=$((nlb_count+1))
  fi
done

alb_monthly=$(monthly "$(awk "BEGIN { print $ALB_HOURLY * $alb_count }")")
nlb_monthly=$(monthly "$(awk "BEGIN { print $NLB_HOURLY * $nlb_count }")")

line "$alb_count × ALB" "£$alb_monthly"
line "$nlb_count × NLB" "£$nlb_monthly"

total=$(awk "BEGIN { print $total + $alb_monthly + $nlb_monthly }")

############################################
# TOTAL
############################################
echo
echo "------------------------------------------------------------"
printf "%-40s %10s\n" "💰 TOTAL ESTIMATED MONTHLY COST" "£$(printf "%.2f" "$total")"
echo "------------------------------------------------------------"
echo
echo "⚠️  Static cost only (no traffic, logs, requests, data transfer)"
