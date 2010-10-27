# nbtfile
#
# Copyright (c) 2010 MenTaLguY
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'zlib'
require 'stringio'

class String
  begin
    alias_method :_nbtfile_getbyte, :getbyte
  rescue NameError
    alias_method :_nbtfile_getbyte, :[]
  end

  begin
    alias_method :_nbtfile_force_encoding, :force_encoding
  rescue NameError
    def _nbtfile_force_encoding(encoding)
    end
  end
end

module NBTFile

TOKENS_BY_INDEX = []
TOKEN_INDICES_BY_TYPE = {}

module Tokens
  tag_names = %w(End Byte Short Int Long Float Double
                 Byte_Array String List Compound)
  tag_names.each_with_index do |tag_name, index|
    tag_name = "TAG_#{tag_name.upcase}"
    symbol = tag_name.downcase.intern
    const_set tag_name, symbol
    TOKENS_BY_INDEX[index] = symbol
    TOKEN_INDICES_BY_TYPE[symbol] = index
  end
end

module CommonMethods
  def sign_bit(n_bytes)
    1 << ((n_bytes << 3) - 1)
  end
end

module ReadMethods
  include Tokens
  include CommonMethods

  def read_raw(io, n_bytes)
    data = io.read(n_bytes)
    raise EOFError unless data and data.length == n_bytes
    data
  end

  def read_integer(io, n_bytes)
    raw_value = read_raw(io, n_bytes)
    value = (0...n_bytes).reduce(0) do |accum, n|
      (accum << 8) | raw_value._nbtfile_getbyte(n)
    end
    value -= ((value & sign_bit(n_bytes)) << 1)
    value
  end

  def read_byte(io)
    read_integer(io, 1)
  end

  def read_short(io)
    read_integer(io, 2)
  end

  def read_int(io)
    read_integer(io, 4)
  end

  def read_long(io)
    read_integer(io, 8)
  end

  def read_float(io)
    read_raw(io, 4).unpack("g").first
  end

  def read_double(io)
    read_raw(io, 8).unpack("G").first
  end

  def read_string(io)
    length = read_short(io)
    string = read_raw(io, length)
    string._nbtfile_force_encoding("UTF-8")
    string
  end

  def read_byte_array(io)
    length = read_int(io)
    read_raw(io, length)
  end

  def read_list_header(io)
    list_type = read_type(io)
    list_length = read_int(io)
    [list_type, list_length]
  end

  def read_type(io)
    byte = read_byte(io)
    begin
      TOKENS_BY_INDEX.fetch(byte)
    rescue IndexError
      raise RuntimeError, "Unexpected tag #{byte}"
    end
  end

  def read_value(io, type, name, state, cont)
    next_state = state

    case type
    when TAG_END
      next_state = cont
      value = nil
    when TAG_BYTE
      value = read_byte(io)
    when TAG_SHORT
      value = read_short(io)
    when TAG_INT
      value = read_int(io)
    when TAG_LONG
      value = read_long(io)
    when TAG_FLOAT
      value = read_float(io)
    when TAG_DOUBLE
      value = read_double(io)
    when TAG_BYTE_ARRAY
      value = read_byte_array(io)
    when TAG_STRING
      value = read_string(io)
    when TAG_LIST
      list_type, list_length = read_list_header(io)
      next_state = ListReaderState.new(state, list_type, list_length)
      value = list_type
    when TAG_COMPOUND
      next_state = CompoundReaderState.new(state)
    end

    [next_state, [type, name, value]]
  end
end

class TopReaderState
  include ReadMethods
  include Tokens

  def get_token(io)
    type = read_type(io)
    raise RuntimeError, "expected TAG_COMPOUND" unless type == TAG_COMPOUND
    name = read_string(io)
    end_state = EndReaderState.new()
    next_state = CompoundReaderState.new(end_state)
    [next_state, [type, name, nil]]
  end
end

class CompoundReaderState
  include ReadMethods
  include Tokens

  def initialize(cont)
    @cont = cont
  end

  def get_token(io)
    type = read_type(io)

    if type != TAG_END
      name = read_string(io)
    else
      name = ""
    end

    read_value(io, type, name, self, @cont)
  end
end

class ListReaderState
  include ReadMethods
  include Tokens

  def initialize(cont, type, length)
    @cont = cont
    @length = length
    @offset = 0
    @type = type
  end

  def get_token(io)
    if @offset < @length
      type = @type
    else
      type = TAG_END
    end

    index = @offset
    @offset += 1

    read_value(io, type, index, self, @cont)
  end
end

class EndReaderState
  def get_token(io)
    [self, nil]
  end
end

class Reader
  def initialize(io)
    @gz = Zlib::GzipReader.new(io)
    @state = TopReaderState.new()
  end

  def each_token
    while tag = get_token()
      yield tag
    end
  end

  def get_token
    @state, tag = @state.get_token(@gz)
    tag
  end
end

module WriteMethods
  include Tokens
  include CommonMethods

  def emit_integer(io, n_bytes, value)
    value -= ((value & sign_bit(n_bytes)) << 1)
    bytes = (1..n_bytes).map do |n|
      byte = (value >> ((n_bytes - n) << 3) & 0xff)
    end
    io.write(bytes.pack("C*"))
  end

  def emit_byte(io, value)
    emit_integer(io, 1, value)
  end

  def emit_short(io, value)
    emit_integer(io, 2, value)
  end

  def emit_int(io, value)
    emit_integer(io, 4, value)
  end

  def emit_long(io, value)
    emit_integer(io, 8, value)
  end

  def emit_float(io, value)
    io.write([value].pack("g"))
  end

  def emit_double(io, value)
    io.write([value].pack("G"))
  end

  def emit_byte_array(io, value)
    emit_int(io, value.length)
    io.write(value)
  end

  def emit_string(io, value)
    emit_short(io, value.length)
    io.write(value)
  end

  def emit_type(io, type)
    emit_byte(io, TOKEN_INDICES_BY_TYPE[type])
  end

  def emit_list_header(io, type, count)
    emit_type(io, type)
    emit_int(io, count)
  end

  def emit_value(io, type, value, capturing, state, cont)
    next_state = state

    case type
    when TAG_BYTE
      emit_byte(io, value)
    when TAG_SHORT
      emit_short(io, value)
    when TAG_INT
      emit_int(io, value)
    when TAG_LONG
      emit_long(io, value)
    when TAG_FLOAT
      emit_float(io, value)
    when TAG_DOUBLE
      emit_double(io, value)
    when TAG_BYTE_ARRAY
      emit_byte_array(io, value)
    when TAG_STRING
      emit_string(io, value)
    when TAG_FLOAT
      emit_float(io, value)
    when TAG_DOUBLE
      emit_double(io, value)
    when TAG_LIST
      next_state = ListWriterState.new(state, value, capturing)
    when TAG_COMPOUND
      next_state = CompoundWriterState.new(state, capturing)
    when TAG_END
      next_state = cont
    else
      raise RuntimeError, "unexpected tag #{type}"
    end

    next_state
  end
end

class TopWriterState
  include WriteMethods
  include Tokens

  def emit_token(io, type, name, value)
    case type
    when TAG_COMPOUND
      emit_type(io, type)
      emit_string(io, name)
      end_state = EndWriterState.new()
      next_state = CompoundWriterState.new(end_state, nil)
      next_state
    end
  end
end

class CompoundWriterState
  include WriteMethods
  include Tokens

  def initialize(cont, capturing)
    @cont = cont
    @capturing = capturing
  end

  def emit_token(io, type, name, value)
    out = @capturing || io

    emit_type(out, type)
    emit_string(out, name) unless type == TAG_END

    emit_value(out, type, value, @capturing, self, @cont)
  end

  def emit_item(io, value)
    raise RuntimeError, "not in a list"
  end
end

class ListWriterState
  include WriteMethods
  include Tokens

  def initialize(cont, type, capturing)
    @cont = cont
    @type = type
    @count = 0
    @value = StringIO.new()
    @capturing = capturing
  end

  def emit_token(io, type, name, value)
    if type == TAG_END
      out = @capturing || io
      emit_list_header(out, @type, @count)
      out.write(@value.string)
    elsif type != @type
      raise RuntimeError, "unexpected type #{type}, expected #{@type}"
    end

    _emit_item(io, type, value)
  end

  def emit_item(io, value)
    _emit_item(io, @type, value)
  end

  def _emit_item(io, type, value)
    @count += 1
    emit_value(@value, type, value, @value, self, @cont)
  end
end

class EndWriterState
  def emit_token(io, type, name, value)
    raise RuntimeError, "unexpected type #{type} after end"
  end

  def emit_item(io, value)
    raise RuntimeError, "not in a list"
  end
end

class Writer
  include WriteMethods

  def initialize(stream)
    @gz = Zlib::GzipWriter.new(stream)
    @state = TopWriterState.new()
  end

  def emit_token(tag, name, value)
    @state = @state.emit_token(@gz, tag, name, value)
  end

  def emit_compound(name=nil)
    emit_token(TAG_COMPOUND, name, nil)
    begin
      yield
    ensure
      emit_token(TAG_END, nil, nil)
    end
  end

  def emit_list(type, name=nil)
    emit_token(TAG_LIST, name, type)
    begin
      yield
    ensure
      emit_token(TAG_END, nil, nil)
    end
  end

  def emit_item(value)
    @state = @state.emit_item(@gz, value)
  end

  def finish
    @gz.close
  end
end

def self.tokenize(io)
  case io
  when String
    io = StringIO.new(io, "rb")
  end
  reader = Reader.new(io)

  reader.each_token do |token|
    yield token
  end
end

def self.load(io)
  root = {}
  stack = [root]

  self.tokenize(io) do |type, name, value|
    case type
    when Tokens::TAG_COMPOUND
      value = {}
    when Tokens::TAG_LIST
      value = []
    when Tokens::TAG_END
      stack.pop
      next
    end

    stack.last[name] = value

    case type
    when Tokens::TAG_COMPOUND, Tokens::TAG_LIST
      stack.push value
    end
  end

  root
end

end
