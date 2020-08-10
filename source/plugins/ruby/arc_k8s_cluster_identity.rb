# frozen_string_literal: true

require "net/http"
require "net/https"
require "uri"
require "yajl/json_gem"
require "base64"
require "time"
require_relative "jwt/jwt"
# require "logger"

class ArcK8sClusterIdentity
  @@cluster_config_crd_api_version = "clusterconfig.azure.com/v1beta1"
  @@cluster_identity_resource_name = "container-insights-clusteridentityrequest"
  @@cluster_identity_resource_namespace = "azure-arc"
  @@cluster_identity_token_secret_namespace = "azure-arc"
  @@cluster_identity_token_secret = "container-insights-clusteridentityrequest-token"
  @@cluster_identity_token_secret_data_name = "cluster-identity-token"
  @@crd_resource_uri_template = "%{kube_api_server_url}/apis/%{cluster_config_crd_api_version}/namespaces/%{cluster_identity_resource_namespace}/azureclusteridentityrequests/%{cluster_identity_resource_name}"
  @@secret_resource_uri_template = "%{kube_api_server_url}/api/v1/namespaces/%{cluster_identity_token_secret_namespace}/secrets/%{token_secret_name}"
  @@azure_monitor_custom_metrics_audience = "https://monitoring.azure.com/"
  @@cluster_identity_request_kind = "AzureClusterIdentityRequest"
  # @LogPath = "/var/opt/microsoft/docker-cimprov/log/arc_k8s_cluster_identity.log"
  # @log = Logger.new(@LogPath, 2, 10 * 1048576) #keep last 2 files, max log file size = 10M

  def initialize
    @token_expiry_time = Time.now
    @cached_access_token = String.new
    @token_file_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    @cert_file_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    @kube_api_server_url = get_kube_api_server_url
    @http_client = get_http_client
    @service_account_token = get_service_account_token
  end

  def get_cluster_identity_token()
    begin
      # get the cluster msi identity token either if its empty or near expirty. Token is valid 24 hrs.
      if @cached_access_token.to_s.empty? || (Time.now + 60 * 60 > @token_expiry_time) # Refresh token 1 hr from expiration
        # renew the token if its near expiry
        if !@cached_access_token.to_s.empty? && (Time.now + 60 * 60 > @token_expiry_time)
          $log.info ("renewing the token since its near expiry")
          renew_near_expiry_token
          # sleep 60 seconds to get the renewed token  available
          sleep 60
        end
        # get the token from secret
        token = get_token_from_secret
        if !token.nil?
          decoded_token = JWT.decode token, nil, false
          expiration = decoded_token[0]["exp"]
          $log.info ("secret expiry: #{expiration}")
          if !expiration.nil?
            @token_expiry_time = Time.at(expiration)
            $log.info ("token secret expiry: #{@token_expiry_time}")
          end
          @cached_access_token = token
        else
          $log.warn ("got token nil from secret: #{@@cluster_identity_token_secret}")
        end
      end
    rescue => err
      $log.warn ("get_cluster_identity_token failed: #{err}")
    end
    return @cached_access_token
  end

  private

  def get_token_from_secret()
    token = nil
    begin
      secret_request_uri = @@secret_resource_uri_template % {
        kube_api_server_url: @kube_api_server_url,
        cluster_identity_token_secret_namespace: @@cluster_identity_token_secret_namespace,
        token_secret_name: @@cluster_identity_token_secret,
      }
      get_request = Net::HTTP::Get.new(secret_request_uri)
      get_request["Authorization"] = "Bearer #{@service_account_token}"
      $log.info "Making GET request to #{secret_request_uri} @ #{Time.now.utc.iso8601}"
      get_response = @http_client.request(get_request)
      $log.info "Got response of #{get_response.code} for #{secret_request_uri} @ #{Time.now.utc.iso8601}"
      if get_response.code.to_i == 200
        token_secret = JSON.parse(get_response.body)["data"]
        cluster_identity_token = token_secret[@@cluster_identity_token_secret_data_name]
        token = Base64.decode64(cluster_identity_token)
      end
    rescue => err
      $log.warn ("get_token_from_secret API call failed: #{err}")
    end
    return token
  end

  private

  def renew_near_expiry_token()
    begin
      crd_request_uri = @@crd_resource_uri_template % {
        kube_api_server_url: @kube_api_server_url,
        cluster_config_crd_api_version: @@cluster_config_crd_api_version,
        cluster_identity_resource_namespace: @@cluster_identity_resource_namespace,
        cluster_identity_resource_name: @@cluster_identity_resource_name,
      }
      update_request = Net::HTTP::Patch.new(crd_request_uri)
      update_request["Content-Type"] = "application/merge-patch+json"
      update_request["Authorization"] = "Bearer #{@service_account_token}"
      update_request_body = get_update_request_body
      update_request.body = update_request_body.to_json
      update_response = @http_client.request(update_request)
      $log.info "Got response of #{update_response.code} for PATCH #{crd_request_uri} @ #{Time.now.utc.iso8601}"
      if update_response.code.to_i == 404
        update_request = Net::HTTP::Post.new(crd_request_uri)
        update_request["Content-Type"] = "application/json"
        update_response = @http_client.request(update_request)
        $log.info "Got response of #{update_response.code} for POST #{crd_request_uri} @ #{Time.now.utc.iso8601}"
      end
    rescue => err
      $log.warn ("renew_near_expiry_token call failed: #{err}")
    end
  end

  private

  def get_service_account_token()
    begin
      if File.exist?(@token_file_path) && File.readable?(@token_file_path)
        token_str = File.read(@token_file_path).strip
        return token_str
      else
        $log.warn ("Unable to read token string from #{@token_file_path}")
        return nil
      end
    end
  end

  private

  def get_http_client()
    kube_api_server_url = get_kube_api_server_url
    base_api_server_url = URI.parse(kube_api_server_url)
    http = Net::HTTP.new(base_api_server_url.host, base_api_server_url.port)
    http.use_ssl = true
    if !File.exist?(@cert_file_path)
      raise "#{@cert_file_path} doesnt exist"
    else
      http.ca_file = @cert_file_path
    end
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    return http
  end

  private

  def get_kube_api_server_url
    if ENV["KUBERNETES_SERVICE_HOST"] && ENV["KUBERNETES_PORT_443_TCP_PORT"]
      return "https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_PORT_443_TCP_PORT"]}"
    else
      $log.warn ("Kubernetes environment variable not set KUBERNETES_SERVICE_HOST: #{ENV["KUBERNETES_SERVICE_HOST"]} KUBERNETES_PORT_443_TCP_PORT: #{ENV["KUBERNETES_PORT_443_TCP_PORT"]}. Unable to form resourceUri")
      return nil
    end
  end

  private

  def get_update_request_body
    body = {}
    body["apiVersion"] = @@cluster_config_crd_api_version
    body["kind"] = @@cluster_identity_request_kind
    body["metadata"] = {}
    body["metadata"]["name"] = @@cluster_identity_resource_name
    body["metadata"]["namespace"] = @@cluster_identity_resource_namespace
    body["spec"] = {}
    body["spec"]["audience"] = @@azure_monitor_custom_metrics_audience
    return body
  end
end
