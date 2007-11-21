require "rubygems"
require "rack"

class String
  def to_param
    URI.escape(self)
  end
  
  def from_param
    URI.unescape(self)
  end
end

class Hash
  def to_params
    map { |k,v| "#{k}=#{URI.escape(v)}" }.join('&')
  end
  
  def symbolize_keys
    self.inject({}) { |h,(k,v)| h[k.to_sym] = v; h }
  end
  
  def pass(*keys)
    reject { |k,v| !keys.include?(k) }
  end
end

class Symbol
  def to_proc 
    Proc.new { |*args| args.shift.__send__(self, *args) }
  end
end

class Array
  def to_hash
    self.inject({}) { |h, (k, v)|  h[k] = v; h }
  end
  
  def to_proc
    Proc.new { |*args| args.shift.send(self[0], args + self[1..-1]) }
  end
end

class Proc
  def block
    self
  end
end

module Enumerable
  def eject(&block)
    find { |e| result = block[e] and break result }
  end
end

module Sinatra
  extend self

  EventContext = Struct.new(:request, :response) do
    def method_missing(name, *args)
      if args.size == 1 && response.respond_to?("#{name}=")
        response.send("#{name}=", args.first)
      else
        response.send(name, *args)
      end
    end
  end
  
  Error = Proc.new do 
    "#{$!.message}\n\t#{$!.backtrace.join("\n\t")}"
  end

  NotFound = Proc.new do 
    "<h1>Not Found</h1>"
  end
  
  def request_types
    @request_types ||= [:get, :put, :post, :delete]
  end
  
  def routes
    @routes ||= Hash.new do |hash, key|
      hash[key] = [] if request_types.include?(key)
    end
  end
  
  def config
    @config ||= {}
  end
  
  def config=(c)
    @config = c
  end
  
  def determine_route(verb, path)
    found = routes[verb].eject { |r| r.match(path) }
    found || routes[404] || NotFound
  end
  
  def call(env)
    request = Rack::Request.new(env)
    response = Rack::Response.new
    route = determine_route(
      request.request_method.downcase.to_sym, 
      request.path_info
    )
    context = EventContext.new(request, response)
    begin
      result = context.instance_eval(&route.block)
      context.body = Array(result.to_s)
      context.finish
    rescue => e
      raise e if config[:raise_errors]
      route = Sinatra.routes[500] || Error
      context.status 500
      context.body Array(context.instance_eval(&route.block))
      context.finish
    end
  end
  
  def define_route(verb, path, &b)
    routes[verb] << route = Route.new(path, &b)
    route
  end
  
  class Route
    
    URI_CHAR = '[^/?:,&#]'.freeze unless defined?(URI_CHAR)
    PARAM = /:(#{URI_CHAR}+)/.freeze unless defined?(PARAM)
    
    attr_reader :block, :path
    
    def initialize(path, &b)
      @path, @block = path, b
      @param_keys = []
      regex = path.to_s.gsub(PARAM) do
        @param_keys << $1.intern
        "(#{URI_CHAR}+)"
      end
      @pattern = /^#{regex}$/
      @struct = Struct.new(:block, :params)
    end
    
    def match(path)
      return nil unless path =~ @pattern
      params = @param_keys.zip($~.captures.map(&:from_param)).to_hash
      @struct.new(@block, params)
    end
    
  end
    
end

def get(path, &b)
  Sinatra.define_route(:get, path, &b)
end
