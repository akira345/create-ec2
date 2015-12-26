# -*- coding: utf-8 -*-
#
require 'aws-sdk-core'
require 'yaml'
require 'pp'
require "optparse"

opts = OptionParser.new

config=YAML.load(File.read("./config/config.yml"))
Aws.config[:credentials] = Aws::Credentials.new(config['access_key_id'],config['secret_access_key'])
ec2_region = "ap-northeast-1"

ec2=Aws::EC2::Client.new(
  region:ec2_region
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
public_ip ||= ec2.allocate_address({ domain: "vpc" }).public_ip
pp public_ip

# functions
#該当するセキュリティグループ名のグループIDを返す
def sg(ec2,vpc_id, *names)
  names = [names].flatten
  tmp = []
  ec2.describe_security_groups({
    filters: [
      {
        name: "vpc-id",
        values: [vpc_id]
      },
      {
        name: "group-name",
        values: names,
      }
    ],
  }).security_groups.each {|g|
    tmp.push(g.group_id)
  }
  return tmp.to_a
end

#該当するEIPのAllocationIDを返す
def eip(ec2,public_ip)
  tmp = ""
  tmp = ec2.describe_addresses({
    filters: [
      { 
        name: "domain",
        values: ["vpc"],
      },
      {
        name: "public-ip",
        values: [public_ip]
      },
    ]
  }).addresses[0].allocation_id
  return tmp.to_s
end

#すでにローカルIPが使用されていないかチェックのため、該当サブネットのすべてのプライベートIPを探索
ary_ips = []
ec2.describe_network_interfaces({
  filters: [
    {
      name: "vpc-id",
      values: [vpc_id]
    },
    {
      name: "subnet-id",
      values: [subnet_id]
    },
  ]
}).network_interfaces.each {|i|
  i.private_ip_addresses.each {|p|
    ary_ips.push(p.private_ip_address)
  }
}

pp ary_ips
if ary_ips.include?(private_ip)
  pp "Duplicate Private IP!!"
  exit 1
end


# AMIから新規マシンを作成。
pp "create"
new_instance = ec2.run_instances({
  image_id: ec2_ami_id,
  instance_type: instance_type,
  min_count: 1,
  max_count: 1,
  subnet_id: subnet_id,
  private_ip_address: private_ip,
  block_device_mappings: [{
    device_name: device_name,
    ebs: {
      volume_size: volume_size,
      delete_on_termination: true,
      volume_type: "standard"
    }
  }],
  security_group_ids: sg(ec2,vpc_id,security_groups),
  placement: { :availability_zone => availability_zone },
  key_name: ssh_keypair_name,
  disable_api_termination: true
})
pp "wait..."
new_instance_id = new_instance.instances[0].instance_id
pp new_instance_id
ec2.wait_until(:instance_running, instance_ids:[new_instance_id])

pp "TAG"
# TAGをつける
# 作成したインスタンスに対してタグを付与
tag_set.each do |key,value|
  ec2.create_tags({
    resources: [new_instance_id],
    tags: [
      {
        key: key,
        value: value,
      }
    ]
  })
end
#ルートボリュームにタグを付与
root_volume_id = ec2.describe_instances({ 
  instance_ids: [new_instance_id],
  filters: [
    {
      name: "block-device-mapping.device-name", 
      values: [device_name],
    },
  ]}).reservations[0].instances[0].block_device_mappings[0].ebs.volume_id

ec2.create_tags({
  resources: [root_volume_id],
  tags: [
    {
      key: 'Name',
      value: "#{hostname}_root",
    }
  ]
})

pp "eip"

# EIP付与
# 割り当てるNICのIDを探索
nic_id = ec2.describe_instances({ 
  instance_ids: [new_instance_id],
  filters: [
    {
      name: "network-interface.addresses.private-ip-address", 
      values: [private_ip],
    },
  ]}).reservations[0].instances[0].network_interfaces[0].network_interface_id
# EIPを割り当てる
ec2.associate_address({
  instance_id: new_instance_id,
  allocation_id: eip(ec2,public_ip),
  network_interface_id: nic_id,
  private_ip_address: private_ip,
})

pp "OK"



