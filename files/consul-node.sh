#!/bin/bash



# Log everything we do.
set -x
exec > /var/log/user-data.log 2>&1

# TODO: actually, userdata scripts run as root, so we can get
# rid of the sudo and tee...

# A few variables we will refer to later...
ASG_NAME="consul-asg"
REGION="us-east-1"
EXPECTED_SIZE="5"

# Update the packages, install CloudWatch tools.
sudo yum update -y
sudo yum install -y awslogs

# Create a config file for awslogs to push logs to the same region of the cluster.
cat <<- EOF | sudo tee /etc/awslogs/awscli.conf
[plugins]
cwlogs = cwlogs
[default]
region = ${region}
EOF

# Create a config file for awslogs to log our user-data log.
cat <<- EOF | sudo tee /etc/awslogs/config/user-data.conf
	[/var/log/user-data.log]
	file = /var/log/user-data.log
	log_group_name = /var/log/user-data.log
	log_stream_name = {instance_id}
EOF

# Create a config file for awslogs to log our docker log.
cat <<- EOF | sudo tee /etc/awslogs/config/docker.conf
	[/var/log/docker]
	file = /var/log/docker
	log_group_name = /var/log/docker
	log_stream_name = {instance_id}
	datetime_format = %Y-%m-%dT%H:%M:%S.%f
EOF

# Start the awslogs service, also start on reboot.
# Note: Errors go to /var/log/awslogs.log
sudo service awslogs start
sudo chkconfig awslogs on

# Install Docker, add ec2-user, start Docker and ensure startup on restart
sudo yum install -y docker
sudo usermod -a -G docker ec2-user
sudo service docker start
sudo chkconfig docker on

# Return the id of each instance in the cluster.
function cluster-instance-ids {
    # Grab every line which contains 'InstanceId', cut on double quotes and grab the ID:
    #    "InstanceId": "i-example123"
    #....^..........^..^.....#4.....^...
    aws --region="$REGION" autoscaling describe-auto-scaling-groups --auto-scaling-group-name $ASG_NAME \
        | grep InstanceId \
        | cut -d '"' -f4
}

# Return the private IP of each instance in the cluster.
function cluster-ips {
    for id in $(cluster-instance-ids)
    do
        aws --region="$REGION" ec2 describe-instances \
            --query="Reservations[].Instances[].[PrivateIpAddress]" \
            --output="text" \
            --instance-ids="$id"
    done
}

# Wait until we have as many cluster instances as we are expecting.
while COUNT=$(cluster-instance-ids | wc -l) && [ "$COUNT" -lt "$EXPECTED_SIZE" ]
do
    echo "$COUNT instances in the cluster, waiting for $EXPECTED_SIZE instances to warm up..."
    sleep 1
done

# Get my IP address, all IPs in the cluster, then just the 'other' IPs...
IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
mapfile -t ALL_IPS < <(cluster-ips)
OTHER_IPS=( ${ALL_IPS[@]/${IP}/} )
echo "Instance IP is: $IP, Cluster IPs are: ${ALL_IPS[@]}, Other IPs are: ${OTHER_IPS[@]}"

# Start the Consul server.
# docker run -d --net=host \
#     --name=consul \
#     -p 8500:8500 \
#     -p 8600:8600/udp \
#     consul:1.5.3 agent -server -ui \
#     -bind=$IP \
#     -client="0.0.0.0" \
#     -retry-join=${OTHER_IPS[0]} -retry-join=${OTHER_IPS[1]} \
#     -retry-join=${OTHER_IPS[2]} -retry-join=${OTHER_IPS[3]} \
    # -bootstrap-expect=$EXPECTED_SIZE
docker run -d --net=host \
    --name=consul \
    -p 8500:8500 \
    -p 8600:8600/udp \
    consul:1.5.3 agent -server -ui \
    -bind=$IP \
    -client="0.0.0.0" \
    -retry-join="provider=aws tag_key=Name tag_value=consulnode" \
    -bootstrap-expect=$EXPECTED_SIZE