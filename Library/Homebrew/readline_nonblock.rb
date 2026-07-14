# typed: strict
# frozen_string_literal: true

class ReadlineNonblock
  BUFFER_SIZE = 4096
  private_constant :BUFFER_SIZE

  sig { params(io: IO).void }
  def initialize(io)
    @io = io
    @buffer = T.let(+"", String)
    @line = T.let(+"", String)
  end

  sig { returns(String) }
  def read
    begin
      index = T.let(nil, T.nilable(Integer))
      loop do
        index = @buffer.index($INPUT_RECORD_SEPARATOR)
        break unless index.nil?

        @line.concat(@buffer)
        @buffer.clear
        @io.read_nonblock(BUFFER_SIZE, @buffer)
      end
      @line.concat(@buffer.slice!(0..index).to_s)
    rescue EOFError
      raise if @line.empty?
    end

    line = @line.freeze
    @line = +""
    line
  end
end
