# Copyright 2015 ClearStory Data, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

include_recipe 'apache_spark::spark-install'
include_recipe 'monit_wrapper'

# Do these at compile time so we can query process status immediately.
package('monit').run_action(:install)
service('monit').run_action(:start)

worker_runner_script = ::File.join(node['apache_spark']['install_dir'], 'worker_runner.sh')

spark_user = node['apache_spark']['user']
spark_group = node['apache_spark']['group']

template worker_runner_script do
  source 'spark_worker_runner.sh.erb'
  mode 0744
  owner spark_user
  group spark_group
  variables node['apache_spark']['standalone'].merge(
    install_dir: node['apache_spark']['install_dir']
  )
end

directory node['apache_spark']['standalone']['worker_work_dir'] do
  mode 0755
  owner spark_user
  group spark_group
  action :create
  recursive true
end

template '/usr/local/bin/clean_spark_worker_dir.rb' do
  source 'clean_spark_worker_dir.rb.erb'
  mode 0755
  owner 'root'
  group 'root'
  variables ruby_interpreter: RbConfig.ruby
end

worker_dir_cleanup_log = node['apache_spark']['standalone']['worker_dir_cleanup_log']
cron 'clean_spark_worker_dir' do
  minute 15
  hour 0
  command '/usr/local/bin/clean_spark_worker_dir.rb ' \
      "--worker_dir #{node['apache_spark']['standalone']['worker_work_dir']} " \
      "--days_retained #{node['apache_spark']['standalone']['job_dir_days_retained']} " \
      "--num_retained #{node['apache_spark']['standalone']['job_dir_num_retained']} " \
      "&>> #{worker_dir_cleanup_log}"
end

# logrotate for the log cleanup script
logrotate_app 'worker-dir-cleanup-log' do
  cookbook 'logrotate'
  path worker_dir_cleanup_log
  frequency 'daily'
  rotate 3  # keep this many logs
  create '0644 root root'
end

# Run Spark standalone worker with Monit
service_name = 'spark-standalone-worker'
master_host_port = format(
  '%s:%d',
  node['apache_spark']['standalone']['master_host'],
  node['apache_spark']['standalone']['master_port'].to_i
)
monit_wrapper_monitor service_name do
  wait_for_host_port master_host_port
  template_source "monit/#{service_name}.conf.erb"
  template_cookbook 'apache_spark'
  variables node['apache_spark']['standalone'].merge(
    install_dir: node['apache_spark']['install_dir'],
    worker_runner_script: worker_runner_script
  )
end

monit_wrapper_service service_name do
  action :start
  wait_for_host_port master_host_port
  restart_action = monit_service_exists_and_running?(service_name) ? :restart : :start
  subscribes restart_action, "package[#{node['apache_spark']['pkg_name']}]", :delayed
  subscribes restart_action, "monit-wrapper_monitor[#{service_name}]", :delayed
  subscribes restart_action, "monit-wrapper_notify_if_not_running[#{service_name}]", :delayed
  subscribes restart_action, "template[#{worker_runner_script}]", :delayed
end
