# Copyright 2019 Pixar

#
#    Licensed under the Apache License, Version 2.0 (the "Apache License")
#    with the following modification; you may not use this file except in
#    compliance with the Apache License and the following modification to it:
#    Section 6. Trademarks. is deleted and replaced with:
#
#    6. Trademarks. This License does not grant permission to use the trade
#       names, trademarks, service marks, or product names of the Licensor
#       and its affiliates, except as required to comply with Section 4(c) of
#       the License and to reproduce the content of the NOTICE file.
#
#    You may obtain a copy of the Apache License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the Apache License with the above modification is
#    distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
#    KIND, either express or implied. See the Apache License for the specific
#    language governing permissions and limitations under the Apache License.
#

# The module
module Jamf

  class Connection

    # A token used for a JSS connection
    class Token

      AUTH_RSRC = 'auth'.freeze

      NEW_TOKEN_RSRC = "#{AUTH_RSRC}/tokens".freeze

      KEEP_ALIVE_RSRC = "#{AUTH_RSRC}/keepAlive".freeze

      INVALIDATE_RSRC = "#{AUTH_RSRC}/invalidateToken".freeze

      # this string is prepended to the token data when used for
      # transaction authorization.
      AUTH_TOKEN_PFX = 'jamf-token '.freeze

      # @return [String] The user who generated this token
      attr_reader :user

      # @return [Jamf::Timestamp]
      attr_reader :expires
      alias expiration expires

      # @return [String] The AUTH_TOKEN_PFX with the token data, used in the
      #   Authorization header of a request
      attr_reader :auth_token

      # @return [URI] The base API url, e.g. https://myjamf.jamfcloud.com/uapi
      attr_reader :base_url

      # when was this token created?
      attr_reader :login_time

      def initialize(**params)
        @valid = false
        @user = params[:user]
        @base_url = params[:base_url].is_a?(String) ? URI.parse(params[:base_url]) : params[:base_url]
        @timeout = params[:timeout] || Jamf::Connection::DFT_TIMEOUT
        @ssl_options = params[:ssl_options] || {}

        if params[:pw]
          init_from_pw params[:pw]
        elsif params[:token_string]
          init_from_token_string params[:token_string]
        else
          raise ArgumentError, 'Must provide either pw: or token_string:'
        end
      end # init

      # Initialize from password
      def init_from_pw(pw)
        resp = token_connection(
          NEW_TOKEN_RSRC,
          pw: pw,
          timeout: @timeout,
          ssl_opts: @ssl_options
        ).post

        if  resp.success?
          parse_token_from_response resp
        elsif resp.status == 401
          raise Jamf::AuthenticationError, 'Incorrect name or password'
        else
          # TODO: better error reporting here
          raise 'An error occurred while authenticating'
        end
      end # init_from_pw

      # Initialize from token string
      def init_from_token_string(str)
        str = "#{AUTH_TOKEN_PFX}#{str}" unless str.start_with? AUTH_TOKEN_PFX
        resp = token_connection(AUTH_RSRC, token: str).get
        raise Jamf::InvalidDataError, 'Token string is not valid' unless resp.success?

        @auth_token = str
        @user = resp.body.dig :account, :username

        # use this token to get a fresh one with a known expiration
        refresh
      end # init_from_token_string

      # @return [String]
      def host
        @base_url.host
      end

      # @return [Integer]
      def port
        @base_url.port
      end

      # @return [String]
      def api_version
        token_connection(Jamf::Connection::SLASH, token: @auth_token ).get.body[:version]
      end

      # @return [Boolean]
      def expired?
        return unless @expires
        Time.now >= @expires
      end

      # @return [Float]
      def secs_remaining
        return unless @expires
        @expires - Time.now
      end

      # @return [String] e.g. "1 week 6 days 23 hours 49 minutes 56 seconds"
      def time_remaining
        return unless @expires
        Jamf.humanize_secs secs_remaining
      end

      # @return [Boolean]
      def valid?
        @valid =
          if expired?
            false
          elsif !@auth_token
            false
          else
            token_connection(AUTH_RSRC, token: @auth_token).get.success?
          end
      end

      # the Jamf::Account object assciated with this token
      def account
        return @account if @account
        resp = token_connection(AUTH_RSRC, token: @auth_token).get
        return unless resp.success?

         @account = Jamf::APIAccount.new resp.body
      end

      # Use this token to get a fresh one
      def refresh
        raise 'Token has expired' if expired?

        keep_alive_token_resp = token_connection(KEEP_ALIVE_RSRC, token: @auth_token).post
        # TODO: better error reporting here
        raise 'An error occurred while authenticating' unless keep_alive_token_resp.success?

        parse_token_from_response keep_alive_token_resp
        # parse_token_from_response keep_alive_rsrc.post('')
        expires
      end
      alias keep_alive refresh

      # Make this token invalid
      def invalidate
        @valid = !token_connection(INVALIDATE_RSRC, token: @auth_token).post.success?
      end
      alias destroy invalidate

      # Private instance methods
      #################################
      private

      # a generic, one-time Faraday connection for token
      # acquision & manipulation
      #
      def token_connection(rsrc, token: nil, pw: nil, timeout: nil, ssl_opts: nil)

        Faraday.new("#{@base_url}/#{rsrc}", ssl: ssl_opts ) do |con|
          con.headers[Jamf::Connection::HTTP_ACCEPT_HEADER] = Jamf::Connection::MIME_JSON
          con.response :json, parser_options: { symbolize_names: true }
          con.options[:timeout] = timeout
          con.options[:open_timeout] = timeout
          if token
            con.headers[:authorization] = token
          else
            con.basic_auth @user, pw
          end
          con.use Faraday::Adapter::NetHttp
        end # Faraday.new
      end # token_connection

      # Parse the API token data into instance vars.
      def parse_token_from_response(resp)
        @token_response_body = resp.body
        @auth_token = AUTH_TOKEN_PFX + @token_response_body[:token]
        @expires = Jamf::Timestamp.new @token_response_body[:expires]
        @login_time = Jamf::Timestamp.new Time.now
        @valid = true
      end

    end # class Token

  end # class Connection

end # module JSS