# typed: strict
# frozen_string_literal: true

require "json"
require "time"
require "cgi"
require "excon"
require "nokogiri"
require "sorbet-runtime"
require "dependabot/registry_client"
require "dependabot/git_submodules"
require "dependabot/package/package_release"
require "dependabot/package/package_details"

module Dependabot
  module GitSubmodules
    module Package
      class PackageDetailsFetcher
        extend T::Sig

        sig do
          params(
            dependency: Dependabot::Dependency,
            credentials: T::Array[Dependabot::Credential]
          ).void
        end
        def initialize(dependency:, credentials:)
          @dependency = dependency
          @credentials = credentials

          @url = T.let(url, String)
        end

        sig { returns(Dependabot::Dependency) }
        attr_reader :dependency

        sig { returns(T::Array[T.untyped]) }
        attr_reader :credentials

        sig { returns(T.nilable(T::Array[Dependabot::Package::PackageRelease])) }
        def available_versions
          versions_metadata = T.let(fetch_tags_and_release_date, T.nilable(T::Array[GitTagWithDetail]))

          # we fallback to the git based tag info if no versions metadata is available
          if versions_metadata&.empty?
            versions_metadata = T.let(fetch_latest_tag_info,
                                      T.nilable(T::Array[GitTagWithDetail]))
          end

          # as git submodules do not have versions (refs/tags are used instead), we use a pseudo version as placeholder
          pseudo_version = T.must(versions_metadata&.length) + 1

          releases = T.must(versions_metadata).map do |version_details|
            version = if GitSubmodules::Version.valid_semver?(version_details.tag)
                        GitSubmodules::Version.new(version_details.tag)
                      elsif version_details.tag.start_with?("v") &&
                            GitSubmodules::Version.valid_semver?(T.must(version_details.tag[1..]))
                        GitSubmodules::Version.new(version_details.tag[1..])
                      else
                        GitSubmodules::Version.new("0.0.0-0.#{pseudo_version -= 1}")
                      end
            Dependabot::Package::PackageRelease.new(
              version: version,
              tag: version_details.tag,
              released_at: version_details.release_date ? Time.parse(T.must(version_details.release_date)) : nil
            )
          end

          releases
        end

        private

        sig { returns(T::Array[GitTagWithDetail]) }
        def fetch_latest_tag_info
          parsed_results = T.let([], T::Array[GitTagWithDetail])

          git_commit_checker = Dependabot::GitCommitChecker.new(
            dependency: dependency,
            credentials: credentials
          )

          parsed_results <<
            GitTagWithDetail.new(
              tag: T.must(git_commit_checker.head_commit_for_current_branch)
            )

          parsed_results
        end

        MAX_COMMITS_TO_FETCH = T.let(5 * Dependabot::GitMetadataFetcher::MAX_COMMITS_PER_PAGE, Integer)

        sig { returns(T::Array[GitTagWithDetail]) }
        def fetch_tags_and_release_date
          parsed_results = T.let([], T::Array[GitTagWithDetail])

          begin
            Dependabot.logger.info("Fetching release info for Git Submodules: #{dependency.name}")

            client = Dependabot::GitCommitChecker.new(
              dependency: dependency,
              credentials: credentials
            )

            sha_to_tags = client.tags.each_with_object({}) do |tag, h|
              sha = tag.commit_sha
              h[sha] ||= []
              h[sha] << tag.name
            end

            sha = T.let(nil, T.nilable(String))
            while parsed_results.length <= MAX_COMMITS_TO_FETCH
              response = sha.nil? ? client.ref_details_for_pinned_ref : client.ref_details(sha)

              unless response.status == 200
                Dependabot.logger.error("Error while fetching details for #{dependency.name} " \
                                        "Detail : #{response.body}")
              end

              return parsed_results unless response.status == 200

              commits = JSON.parse(response.body)
              break if commits.length <= (sha.nil? ? 0 : 1)

              commits.each_with_index do |release, index|
                next if index == 0 && !sha.nil?  # Skip the first commit if we are in a paginated request
                sha = release["sha"]
                release_date = release["commit"]["committer"]["date"]
                Array(sha_to_tags[sha]).each do |tag_name|
                  parsed_results << GitTagWithDetail.new(
                    tag: tag_name,
                    release_date: release_date
                  )
                end
                parsed_results << GitTagWithDetail.new(
                  tag: sha,
                  release_date: release_date
                )
              end

              break if commits.length < Dependabot::GitMetadataFetcher::MAX_COMMITS_PER_PAGE
            end

            parsed_results
          rescue StandardError => e
            Dependabot.logger.error("Error while fetching package info for git submodule: #{e.message}")
            parsed_results
          end
        end

        sig { returns(String) }
        def url
          dependency.source_details&.fetch(:url, nil)
        end
      end
    end
  end
end
