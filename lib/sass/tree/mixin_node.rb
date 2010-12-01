require 'sass/tree/node'

module Sass::Tree
  # A static node representing a mixin include.
  # When in a static tree, the sole purpose is to wrap exceptions
  # to add the mixin to the backtrace.
  #
  # @see Sass::Tree
  class MixinNode < Node
    # @see Node#options=
    def options=(opts)
      super
      @args.each {|a| a.context = :equals} if opts[:sass2]
      @keywords.each {|k, v| v.context = :equals} if opts[:sass2]
    end

    # @param name [String] The name of the mixin
    # @param args [Array<Script::Node>] The arguments to the mixin
    # @param keywords [{String => Script::Node}] A hash from keyword argument names to values
    def initialize(name, args, keywords)
      @name = name
      @args = args
      @keywords = keywords
      super()
    end

    # @see Node#cssize
    def cssize(extends, parent = nil)
      _cssize(extends, parent) # Pass on the parent even if it's not a MixinNode
    end

    protected

    # @see Node#to_src
    def to_src(tabs, opts, fmt)
      unless @args.empty? && @keywords.empty?
        args = @args.map {|a| a.to_sass(opts)}.join(", ")
        keywords = @keywords.map {|k, v| "$#{dasherize(k, opts)}: #{v.to_sass(opts)}"}.join(', ')
        arglist = "(#{args}#{', ' unless args.empty? || keywords.empty?}#{keywords})"
      end
      "#{'  ' * tabs}#{fmt == :sass ? '+' : '@include '}#{dasherize(@name, opts)}#{arglist}#{semi fmt}\n"
    end

    # @see Node#_cssize
    def _cssize(extends, parent)
      children.map do |c|
        parent.check_child! c
        c.cssize(extends, parent)
      end.flatten
    rescue Sass::SyntaxError => e
      e.modify_backtrace(:mixin => @name, :filename => filename, :line => line)
      e.add_backtrace(:filename => filename, :line => line)
      raise e
    end

    # Runs the mixin.
    #
    # @param environment [Sass::Environment] The lexical environment containing
    #   variable and mixin values
    # @raise [Sass::SyntaxError] if there is no mixin with the given name
    # @raise [Sass::SyntaxError] if an incorrect number of arguments was passed
    # @see Sass::Tree
    def perform!(environment)
      handle_include_loop!(environment) if environment.mixins_in_use.include?(@name)

      original_env = environment
      original_env.push_frame(:filename => filename, :line => line)
      original_env.prepare_frame(:mixin => @name)
      raise Sass::SyntaxError.new("Undefined mixin '#{@name}'.") unless mixin = environment.mixin(@name)

      passed_args = @args.dup
      passed_keywords = @keywords.dup

      raise Sass::SyntaxError.new(<<END.gsub("\n", "")) if mixin.args.size < passed_args.size
Mixin #{@name} takes #{mixin.args.size} argument#{'s' if mixin.args.size != 1}
 but #{@args.size} #{@args.size == 1 ? 'was' : 'were'} passed.
END

      passed_keywords.each do |name, value|
        # TODO: Make this fast
        unless mixin.args.find {|(var, default)| var.underscored_name == name}
          raise Sass::SyntaxError.new("Mixin #{@name} doesn't have an argument named $#{name}")
        end
      end

      environment = mixin.args.zip(passed_args).
        inject(Sass::Environment.new(mixin.environment)) do |env, ((var, default), value)|
        env.set_local_var(var.name,
          if value
            value.perform(environment)
          elsif kv = passed_keywords[var.underscored_name]
            kv.perform(env)
          elsif default
            val = default.perform(env)
            if default.context == :equals && val.is_a?(Sass::Script::String)
              val = Sass::Script::String.new(val.value)
            end
            val
          end)
        raise Sass::SyntaxError.new("Mixin #{@name} is missing parameter #{var.inspect}.") unless env.var(var.name)
        env
      end

      self.children = mixin.tree.map {|c| c.perform(environment)}.flatten
    rescue Sass::SyntaxError => e
      if original_env # Don't add backtrace info if this is an @include loop
        e.modify_backtrace(:mixin => @name, :line => @line)
        e.add_backtrace(:line => @line)
      end
      raise e
    ensure
      original_env.pop_frame if original_env
    end

    private

    def handle_include_loop!(environment)
      msg = "An @include loop has been found:"
      mixins = environment.stack.map {|s| s[:mixin]}.compact
      if mixins.size == 2 && mixins[0] == mixins[1]
        raise Sass::SyntaxError.new("#{msg} #{@name} includes itself")
      end

      mixins << @name
      msg << "\n" << Sass::Util.enum_cons(mixins, 2).map do |m1, m2|
        "    #{m1} includes #{m2}"
      end.join("\n")
      raise Sass::SyntaxError.new(msg)
    end
  end
end
