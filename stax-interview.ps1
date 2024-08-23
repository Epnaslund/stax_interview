#region setup security groups
#EC2 SG and rule
$ec2SG = aws ec2 create-security-group `
    --group-name StaxEC2-SG01 `
    --vpc-id vpc-07a5de02eedcea38b `
    --description "Stax Interview SG for EC2 Instance" `
     | convertfrom-json
aws ec2 authorize-security-group-ingress `
    --group-id $($ec2SG.GroupID) `
    --protocol tcp `
    --port 443 `
    --cidr 0.0.0.0/0
#ALB SG and rules
$albSG = aws ec2 create-security-group `
    --group-name StaxALB-SG01 `
    --vpc-id vpc-07a5de02eedcea38b `
    --description "Stax Interview SG for Application Load Balancer" `
    | convertfrom-json
aws ec2 authorize-security-group-ingress `
    --group-id $($AlbSG.GroupID) `
    --protocol tcp `
    --port 443 `
    --cidr 0.0.0.0/0 
aws ec2 authorize-security-group-egress  `
    --group-id $($AlbSG.GroupID) `
    --protocol tcp `
    --port 443 `
    --cidr 0.0.0.0/0
#endregion setup security groups

#region setup EC2 host
$ec2Instance = aws ec2 run-instances `
    --image-id "ami-02c21308fed24a8ab" `
    --instance-type "t2.micro" `
    --security-group-ids $($ec2SG.GroupID) `
    --subnet-id "subnet-0ddfadc6d9ea947f9" `
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=StaxWeb01}]' `
    --user-data @"
#!/bin/bash
sudo yum install httpd
sudo systemctl is-enabled httpd
sleep 5
sudo yum update -y
sudo yum install -y mod_ssl
sudo systemctl start httpd
sudo systemctl enable httpd
cd /etc/pki/tls/certs
sudo ./make-dummy-cert localhost.crt
sudo sed -i '/SSLCertificateKeyFile \/etc\/pki\/tls\/private\/localhost.key/s/^/#/' /etc/httpd/conf.d/ssl.conf
sudo bash -c 'cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
<title>Stax Interview</title>
</head>
<body>
<p>Hello World! Thanks for the time and opportunity. -Erik</p>
</body>
</html>
EOF'
"@
#endregion setup EC2 host

#region setup target group
#need to wait for the ec2 insatance to be ready:
$instanceID = ($ec2Instance | convertfrom-json).instances.instanceid
aws ec2 wait instance-running --instance-ids $instanceID
#aws ec2 wait instance-status-ok --instance-ids $instanceID
$ec2TG = aws elbv2 create-target-group `
    --name StaxWebTG01 `
    --protocol HTTPS `
    --port 443 `
    --vpc-id vpc-07a5de02eedcea38b `
    --health-check-protocol HTTPS `
    --health-check-port 443 `
    --health-check-path /index.html `
    --matcher HttpCode=200
$targetGroupArn = ($ec2TG | ConvertFrom-Json).TargetGroups[0].TargetGroupArn
#register the ec2 instance as a target
aws elbv2 register-targets `
    --target-group-arn $targetGroupArn `
    --targets Id=$instanceID
#endregion setup target group

#region setup application load balancer
$loadBalancer = aws elbv2 create-load-balancer `
    --name StaxWebLB01 `
    --subnets subnet-08fccd0c7f42f56b0 subnet-0679c98dfdd88c0cf `
    --security-groups $($ec2SG.GroupID) `
    --scheme internet-facing `
    --type application `
    --ip-address-type ipv4
#get alb arn for setting up listener
$loadBalancerArn = ($loadBalancer | ConvertFrom-Json).LoadBalancers[0].LoadBalancerArn
#get alb details for later use in setting up dns
$loadBalancerDetails = $loadBalancer | ConvertFrom-Json
$albHostedZoneId = $loadBalancerDetails.LoadBalancers[0].CanonicalHostedZoneId
$albDnsName = $loadBalancerDetails.LoadBalancers[0].DNSName
#get certiciate:
$certificateArn = aws acm list-certificates --query 'CertificateSummaryList[*].CertificateArn' --output text
#setup Listener 
aws elbv2 create-listener `
    --load-balancer-arn $loadBalancerArn `
    --protocol HTTPS `
    --port 443 `
    --default-actions Type=forward,TargetGroupArn=$targetGroupArn `
    --ssl-policy 'ELBSecurityPolicy-TLS-1-2-2017-01' `
    --certificates "CertificateArn=$certificateArn"
#endregion setup application load balancer

#region setup DNS
$hostedZoneId = (aws route53 list-hosted-zones --query 'HostedZones[?Name==`"naslund.cloud.`"].Id' --output text).Split("/")[2]
$recordSetName = "stax.naslund.cloud."
$changeBatch = @"
{
    \"Changes\": [
        {
            \"Action\": \"UPSERT\",
            \"ResourceRecordSet\": {
                \"Name\": \"$recordSetName\",
                \"Type\": \"A\",
                \"AliasTarget\": {
                    \"HostedZoneId\": \"$albHostedZoneId\",
                    \"DNSName\": \"$albDnsName\",
                    \"EvaluateTargetHealth\": false
                }
            }
        }
    ]
}
"@
aws route53 change-resource-record-sets `
    --hosted-zone-id $hostedZoneId `
    --change-batch $changeBatch
#endregion setup DNS

#region cleanup resources
#remove DNS
$recordSetName = "stax.naslund.cloud."
$deleteChangeBatch = @"
{
	\"Changes\": [
		{
			\"Action\": \"DELETE\",
			\"ResourceRecordSet\": {
				\"Name\": \"$recordSetName\",
				\"Type\": \"A\",
				\"AliasTarget\": {
					\"HostedZoneId\": \"$albHostedZoneId\",
					\"DNSName\": \"$albDnsName\",
					\"EvaluateTargetHealth\": false
				}
			}
		}
	]
}
"@
aws route53 change-resource-record-sets `
	--hosted-zone-id $hostedZoneId `
	--change-batch $deleteChangeBatch

#remove ALB
aws elbv2 delete-load-balancer --load-balancer-arn $loadBalancerArn
aws elbv2 wait load-balancers-deleted --load-balancer-arns $loadBalancerArn

#remove target group
aws elbv2 delete-target-group --target-group-arn $targetGroupArn

#terminate EC2 instance
aws ec2 terminate-instances --instance-ids $instanceID
aws ec2 wait instance-terminated --instance-ids $instanceID

#remove security groups
aws ec2 delete-security-group --group-id $($ec2SG.GroupID)
aws ec2 delete-security-group --group-id $($albSG.GroupID)
#endregion cleanup resources