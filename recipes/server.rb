#
# Author:: Seth Chisamore (<schisamo@chef.io>)
# Cookbook:: sql_server
# Recipe:: server
#
# Copyright:: 2011-2017, Chef Software, Inc.
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
#

Chef::Application.fatal!("node['sql_server']['server_sa_password'] must be set for this cookbook to run") if node['sql_server']['server_sa_password'].nil?

config_file_path = win_friendly_path(File.join(Chef::Config[:file_cache_path], 'ConfigurationFile.ini'))

sql_sys_admin_list = if node['sql_server']['sysadmins'].is_a? Array
                       node['sql_server']['sysadmins'].map { |account| %("#{account}") }.join(' ') # surround each in quotes, space delimit list
                     else
                       %("#{node['sql_server']['sysadmins']}") # surround in quotes
                     end

template config_file_path do
  source 'ConfigurationFile.ini.erb'
  variables(
    sqlSysAdminList: sql_sys_admin_list
  )
end

version = node['sql_server']['version']
x86_64 = node['kernel']['machine'] =~ /x86_64/

package_url = node['sql_server']['server']['url'] ||
              SqlServer::Helper.sql_server_url(version, x86_64) ||
              Chef::Application.fatal!("No package URL matches '#{version}'. node['sql_server']['server']['url'] must be set or node['sql_server']['version'] must match a supported version.")

package_name = node['sql_server']['server']['package_name'] ||
               SqlServer::Helper.sql_server_package_name(version, x86_64) ||
               Chef::Application.fatal!("No package name matches '#{version}'. node['sql_server']['server']['package_name'] must be set or node['sql_server']['version'] must match a supported version.")

package_checksum = node['sql_server']['server']['checksum'] ||
                   SqlServer::Helper.sql_server_checksum(version, x86_64) ||
                   Chef::Application.fatal!("No package checksum matches '#{version}'. node['sql_server']['server']['checksum'] must be set or node['sql_server']['version'] must match a supported version.")

# Build safe password command line options for the installer
# see http://technet.microsoft.com/library/ms144259
passwords_options = {
  AGTSVCPASSWORD: node['sql_server']['agent_account_pwd'],
  RSSVCPASSWORD:  node['sql_server']['rs_account_pwd'],
  SQLSVCPASSWORD: node['sql_server']['sql_account_pwd'],
}.map do |option, attribute|
  next unless attribute
  # Escape password double quotes and backslashes
  safe_password = attribute.gsub(/["\\]/, '\\\\\0')
  # When the number of double quotes is odd, we need to escape the enclosing quotes
  enclosing_escape = safe_password.count('"').odd? ? '^' : ''
  "/#{option}=\"#{safe_password}#{enclosing_escape}\""
end.compact.join ' '
is_sqlserver_installed = is_package_installed?(package_name)

filename = File.basename(package_url).downcase
fileextension = File.extname(filename)
is_iso = ['.iso'].include? fileextension

include_recipe 'seven_zip' if is_iso

download_path = "#{Chef::Config['file_cache_path']}/#{filename}"
remote_file download_path do
  source package_url
  checksum package_checksum
  only_if { is_iso }
end

directory "#{Chef::Config['file_cache_path']}/sql_server" do
  recursive true
end

iso_extraction_dir = "#{Chef::Config['file_cache_path']}/sql_server/#{package_checksum}"

execute 'extract_iso' do
  command "\"#{File.join(node['seven_zip']['home'], '7z.exe')}\" x -y -o\"#{iso_extraction_dir}\" #{download_path}"
  only_if { is_iso && !(::File.directory?(iso_extraction_dir)) }
end

windows_package package_name do
  source !is_iso ? package_url : "#{iso_extraction_dir}/#{node['sql_server']['server']['setup']}"
  checksum !is_iso ? package_checksum : nil
  timeout node['sql_server']['server']['installer_timeout']
  installer_type :custom
  options "/q /ConfigurationFile=#{config_file_path} #{passwords_options}"
  action :install
  notifies :request_reboot, 'reboot[sql server install]'
  not_if {is_sqlserver_installed}
  returns [0, 42, 127, 3010]
end

# SQL Server requires a reboot to complete your install
reboot 'sql server install' do
  action :nothing
  reason 'Needs to reboot after installing SQL Server'
  only_if { reboot_pending? }
end

include_recipe 'sql_server::configure'
if iso_install
  powershell_script 'Dismount #{filename}' do
    code <<-EOH
      Dismount-DiskImage -ImagePath "#{download_path}"
      EOH
    not_if {is_sqlserver_installed}
  end
end