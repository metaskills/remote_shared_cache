# Copyright 2008 Ken Collins, Decisiv Inc.
# Distributed via MIT license
# Feedback appreciated: kcollins at [nospam] decisiv dt net

require 'capistrano/recipes/deploy/strategy/copy'

module Capistrano
  module Deploy
    module Strategy
      

      # This class implements the strategy for deployment which uses a remote shared cache that is assumed to be 
      # accessible by each target host. The remote cache is a SCM export created in one of the following two ways.
      # 
      #   1) If :remote_repository_access is not set or is false, a local export is made, compressed
      #      and copied to the target host and uncompressed to the remote shared cache.
      #   2) If :remote_repository_access returns true, the target host will perform a direct SCM 
      #      export to the remote shared cache.
      # 
      # Despite which method is used above, the creation of the remote shared cache will only target the primary 
      # app server using the primary_app_server() method. Again all other app targets assume that this is a 
      # shared directory accessbile to all. This yeilds faster deployments since capistrano does not have to 
      # locally prepare/compress/copy the source to each host.
      # 
      # This development strategy inherets from the normal Copy deployment strategy and uses many of the same 
      # metods/configurations available to that class when needing to perform local export and copy of the source.
      # Examples include, :copy_compression, :copy_remote_dir, :copy_dir. Configurations specific to this strategy 
      # includes, :shared_cache_dir (parent of all cached revisions) and :remote_repository_access (which determins 
      # what method is used above to create the shared cache).
      
      class RemoteSharedCache < Copy
        
        def deploy!
          add_rollback { with_primary_app_server {run "rm -rf #{revision_cache_dir}; true"} }
          force_export_copy_strategy
          create_remote_shared_cache
          copy_remote_shared_cache_to_release_path
        end
        
        def check!
          super.check {}
        end
        
        
        private
        
        # Returns the shared directory for all exported revisions to be organized under. This really should 
        # be customized and not left to its default. A good example would be a mount point for a network drive 
        # that all target servers could reach.
        def shared_cache_dir
          configuration[:shared_cache_dir] || File.join(shared_path,'shared_repository_caches')
        end
        
        # The specific revision directory within the shared cache directory.
        def revision_cache_dir
          File.join(shared_cache_dir,revision.to_s)
        end
        
        # Returns weather the repository is accessible from the remote target server or not.
        def remote_repository_access?
          configuration[:remote_repository_access] == true
        end
        
        # Finds the first app server with a primary => true option or the lucky first in the app roles collection.
        def primary_app_server
          @primary_app_server ||= find_servers(:roles => :app, :only => {:primary => true}).first || find_servers(:roles => :app).first
        end
        
        # Wraps caps with_env() method scoped to the primary app server.
        def with_primary_app_server(&block)
          with_env('HOSTS',primary_app_server.to_s) { yield }
        end
        
        # A small extension to Capistrano::Configuration::Execution that adds a rollback to the existing task_call_frames.
        def add_rollback(&block)
          existing_rollback = task_call_frames.last.rollback
          task_call_frames.last.rollback = lambda { block.call ; existing_rollback.call }
        end
        
        # The releases directory in the remote_dir directory where remote_filename is uncompressed to.
        def remote_tmp_release_dir
          @remote_tmp_release_dir ||= File.join(remote_dir, File.basename(destination))
        end
        
        # Set the :copy_strategy to :export in so many ways.
        def force_export_copy_strategy
          set :copy_strategy, :export
          @copy_strategy = :export
        end
        
        # Will delegate the creation of the remote shared cache to the proper methods depending on the accessibility 
        # of the repository from the remote host. Method is scoped to the primary app server and will only create the 
        # the cache for this revision when it does not exist.
        def create_remote_shared_cache
          with_primary_app_server do
            unless Capistrano::Deploy::Dependencies.new(configuration).remote.directory(revision_cache_dir).pass?
              remote_repository_access? ? direct_export_remote_shared_cache : local_export_and_copy_remote_shared_cache
            end
          end
        end
        
        # Performs a SCM export on remote host for this revision to the shared cache directory.
        def direct_export_remote_shared_cache
          logger.debug "Performing a direct :export to #{revision_cache_dir}"
          run "#{source.export(revision,revision_cache_dir)} && (echo #{revision} > #{revision_cache_dir}/REVISION)"
        end
        
        # Performs a SCM export locally, compresses it, transfers it to the server, uncompresses it and then creates 
        # the directory for this revision in the shared cache. Removes all remote artifacts.
        def local_export_and_copy_remote_shared_cache
          logger.debug "Performing a local :export of revision #{revision} to #{destination}"
          system(command)
          File.open(File.join(destination,"REVISION"), "w") { |f| f.puts(revision) }
          logger.debug "Compressing #{destination} to #{filename}"
          Dir.chdir(tmpdir) { system(compress(File.basename(destination), File.basename(filename)).join(" ")) }
          content = File.open(filename, "rb") { |f| f.read }
          put content, remote_filename
          run "umask 02 && mkdir -p #{revision_cache_dir}"
          uncompress_and_move_command = "cd #{remote_dir} && #{decompress(remote_filename).join(" ")} && " + 
            "cp -RPp #{remote_tmp_release_dir}/* #{revision_cache_dir} && " +
            "rm #{remote_filename} && rm -rf #{remote_tmp_release_dir}"
          run(uncompress_and_move_command)
        ensure
          FileUtils.rm filename rescue nil
          FileUtils.rm_rf destination rescue nil
        end
        
        # Does the finaly work by first creating this release path and then copying the contents of the remote shared 
        # cache for this revision to this new release path.
        def copy_remote_shared_cache_to_release_path
          logger.debug "Copying the remote shared cache to release path"
          run "mkdir -p #{configuration[:release_path]} && cp -RPp #{revision_cache_dir}/* #{configuration[:release_path]}"
        end
        
      end
      
      
    end
  end
end


