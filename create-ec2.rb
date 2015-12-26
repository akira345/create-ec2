# -*- coding: utf-8 -*-
#
require 'aws-sdk-v1'
require 'yaml'
require 'pp'
require "optparse"

opts = OptionParser.new

config=YAML.load(File.read("./config/config.yml"))
AWS.config(config)
ec2_region = "ec2.ap-northeast-1.amazonaws.com"

ec2 = AWS::EC2.new(
  :ec2_endpoint => ec2_region
)

#　引数
opts = OptionParser.new
instance_type = nil

opts.on("-t","--instance_type INSTANCE_TYPE") do |type|
  instance_type = type
end
private_ip = nil
opts.on("-i","--private_ip PRIVATE_IP") do |ip|
  private_ip = ip
end
volume_size = nil
opts.on("-s","--volume_size VOLUME_SIZE") do |size|
  volume_size = size
end
device_name = nil
opts.on("-d","--device_name DEVICE_NAME") do |device|
  device_name = device
end
hostname = nil
opts.on("-h","--hostname HOSTNAME") do |host|
  hostname = host
end
public_ip = nil
opts.on("-e","--elastic_ip ELASTIC_IP") do |eip|
  public_ip = eip
end
opts.parse!(ARGV)

#debug
#instance_type= "t2.micro"
#private_ip = "10.0.0.100"
#volume_size = 8
#device_name = "/dev/xvda"
#hostname = "exsample.com"
#public_ip = "xx.xx.xx.xx"


# 基本パラメタ
param=YAML.load(File.read("./param.yml"))

security_groups = param["security_groups"]
ec2_ami_id = param["ec2_ami_id"]
vpc_id = param["vpc_id"]
subnet_id = param["subnet_id"]
availability_zone = param["availability_zone"]
ssh_keypair_name = param["ssh_keypair_name"]

# Nameの他にデフォで設定するタグ名を設定
tag_set = {"Name"=>hostname,"backup"=>"on"}

#eipの指定がなければ自動取得。取得できなかった場合の例外処理は省略
public_ip ||= ec2.elastic_ips.create(vpc: vpc_id).ip_address.to_s
pp public_ip

# functions
#存在するセキュリティグループを返す
def sg(ec2,vpc_id, *names)
  names = [names].flatten
  tmp = []
  ec2.security_groups.select {|s| s.vpc? && s.vpc.id == vpc_id && names.include?(s.name) }.each {|d|
    tmp.push(d.id)
  }
  return tmp.to_a
end
#存在するEIPを返す
def eip(ec2,public_ip)
  tmp = ""
  ec2.elastic_ips.select {|i| i.public_ip.include?(public_ip) }.each {|d|
    tmp = d.allocation_id
  }
  return tmp.to_s
end

#すでにローカルIPが使用されていないか？
ary_ips = []
ec2.client.describe_network_interfaces(filters: [{ name: "vpc-id",values: [vpc_id]},{name: "subnet-id",values: [subnet_id]}])[:network_interface_set].each {|d|
  d[:private_ip_addresses_set].each {|dd|
    ary_ips.push(dd[:private_ip_address])
  }
}

if ary_ips.include?(private_ip)
  pp "Duplicate Private IP!!"
  exit 1
end


# AMIから新規マシンを作成。
pp "create"

new_instance = ec2.instances.create({
  :image_id => ec2_ami_id,
  :instance_type => instance_type,
  :count =>1,
  :subnet => subnet_id,
  :private_ip_address => private_ip,
  :block_device_mappings => [{
    :device_name => device_name,
    :ebs => {
      :volume_size => volume_size,
      :delete_on_termination => true,
      :volume_type => "standard"
    }
  }],
  :security_group_ids => sg(ec2,vpc_id,security_groups),
  :availability_zone => availability_zone,
  :key_pair => ec2.key_pairs[ssh_keypair_name],
  :disable_api_termination => true
})
pp "wait..."
sleep 10 while new_instance.status == :pending

new_instance_id = new_instance.id
pp new_instance_id

pp "TAG"
# TAGをつける
tag_set.each do |key,value|
  new_instance.add_tag(key,:value => value)
end
root_volume = new_instance.attachments[device_name].volume
ec2.tags.create(root_volume, 'Name', value: "#{hostname}_root")

pp "eip"
# EIP付与
new_instance.associate_elastic_ip(eip(ec2,public_ip))

pp "OK"



