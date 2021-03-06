# Copyright (C) 2021 Giuseppe Bilotta <giuseppe.bilotta@gmail.com>
# This software is licensed under the MIT license. See LICENSE for details

require 'asciidoctor/extensions'
require 'fileutils'

class LiterateProgrammingTreeProcessor < Asciidoctor::Extensions::TreeProcessor
  def initialize config = {}
    super config
    @roots = Hash.new { |hash, key| hash[key] = [] }
    @chunks = Hash.new { |hash, key| hash[key] = [] }
    @chunk_names = Set.new
    @line_directive = { default: '#line %{line} "%{file}"' }
    @chunk_blocks = Hash.new { |hash, key| hash[key] = [] }
  end

  def full_title string
    pfx = string.chomp("...")
    # nothing to do if title was not shortened
    return string if string == pfx
    hits = @chunk_names.find_all { |s| s.start_with? pfx }
    raise ArgumentError, "No chunk #{string}" if hits.length == 0
    raise ArgumentError, "Chunk title #{string} is not unique" if hits.length > 1
    hits.first
  end
  def output_line_directive file, fname, lineno
    file.puts(@line_directive[:default] % { line: lineno, file: fname}) unless @line_directive[:default].empty?
  end
  def is_chunk_ref line
    if line.match /^(\s*)<<(.*)>>\s*$/
      return full_title($2), $1
    else
      return false
    end
  end
  def add_chunk_id chunk_title, block
    block_count = @chunk_blocks[chunk_title].append(block).size
    title_for_id = "_chunk_#{chunk_title}_block_#{block_count}"
    new_id = Asciidoctor::Section.generate_id title_for_id, block.document
    # TODO error handling
    block.document.register :refs, [new_id, block]
    block.id = new_id unless block.id
  end
  def recursive_tangle file, chunk_name, indent, chunk, stack
    stack.add chunk_name
    fname = ''
    lineno = 0
    chunk.each do |line|
      case line
      when Asciidoctor::Reader::Cursor
        fname = line.file
        lineno = line.lineno + 1
        output_line_directive(file, fname, lineno)
      when String
        lineno += 1
        ref, new_indent = is_chunk_ref line
        if ref
          # must not be in the stack
          raise RuntimeError, "Recursive reference to #{ref} from #{chunk_name}" if stack.include? ref
          # must be defined
          raise ArgumentError, "Found reference to undefined chunk #{ref}" unless @chunks.has_key? ref
          recursive_tangle file, ref, indent + new_indent, @chunks[ref], stack
          output_line_directive(file, fname, lineno)
        else
          file.puts line.empty? ? line : indent + line
        end
      else
        raise TypeError, "Unknown chunk element #{line.inspect}"
      end
    end
    stack.delete chunk_name
  end
  def tangle doc
    line_template = doc.attributes['litprog-line-template']
    if line_template # attribute is set
      @line_directive[:default] = line_template
    end
    docdir = doc.attributes['docdir']
    outdir = doc.attributes['litprog-outdir']
    if outdir and not outdir.empty?
      outdir = File.join(docdir, outdir)
      FileUtils.mkdir_p outdir
    else
      outdir = docdir
    end
    @roots.each do |name, initial_chunk|
      if name == '*'
        recursive_tangle STDOUT, name, '', initial_chunk, Set[]
      else
        full_path = File.join(outdir, name)
        File.open(full_path, 'w') do |f|
          recursive_tangle f, name, '', initial_chunk, Set[]
        end
      end
    end
  end
  def add_to_chunk chunk_hash, chunk_title, block_lines
    @chunk_names.add chunk_title
    chunk_hash[chunk_title] += block_lines

    block_lines.each do |line|
      mentioned, _ = is_chunk_ref line
      @chunk_names.add mentioned if mentioned
    end
  end
  def process_source_block block
    chunk_hash = @chunks
    if block.attributes.has_key? 'output'
      chunk_hash = @roots
      chunk_title = block.attributes['output']
      raise ArgumentError, "Duplicate root chunk for #{chunk_title}" if @roots.has_key?(chunk_title)
    else
      # We use the block title (TODO up to the first full stop or colon) as chunk name
      title = block.attributes['title']
      chunk_title = full_title title
      block.title = chunk_title if title != chunk_title
    end
    chunk_hash[chunk_title].append(block.source_location)
    add_to_chunk chunk_hash, chunk_title, block.lines
    add_chunk_id chunk_title, block
  end
  CHUNK_DEF_RX = /^<<(.*)>>=\s*$/
  def process_listing_block block
    return if block.lines.empty?
    return unless block.lines.first.match(CHUNK_DEF_RX)
    chunk_titles = [ full_title($1) ]
    block_location = block.source_location
    chunk_offset = 0
    block.lines.slice_when do |l1, l2|
      l2.match(CHUNK_DEF_RX) and chunk_titles.append(full_title $1)
    end.each do |lines|
      chunk_title = chunk_titles.shift
      block_lines = lines.drop 1
      chunk_hash = @chunks
      unless chunk_title.include? " "
        chunk_hash = @roots
        raise ArgumentError, "Duplicate root chunk for #{chunk_title}" if @roots.has_key?(chunk_title)
      end
      chunk_location = block_location.dup
      chunk_location.advance(chunk_offset + 1)
      chunk_hash[chunk_title].append(chunk_location)
      chunk_offset += lines.size
      add_to_chunk chunk_hash, chunk_title, block_lines
      add_chunk_id chunk_title, block
    end
  end
  def weave doc
    @chunk_blocks.each do |chunk_title, block_list|
      last_block_index = block_list.size - 1
      block_list.each_with_index do |block, i|
        prevlink = " [.prevlink]#<<#{block_list[i-1].id},prev>>#" if i > 0
        nextlink = " [.nextlink]#<<#{block_list[i+1].id},next>>#" if i != last_block_index
        if prevlink or nextlink
          prevlink ||= ""
          nextlink ||= ""
          block.title = block.title + prevlink + nextlink
        end
        # TODO
      end
    end
  end
  def process doc
    doc.find_by context: :listing do |block|
      if block.style == 'source'
        process_source_block block
      else
        process_listing_block block
      end
    end
    tangle doc
    weave doc
    doc
  end
end

Asciidoctor::Extensions.register do
  preprocessor do
    process do |doc, reader|
      doc.sourcemap = true
      nil
    end
  end
  tree_processor LiterateProgrammingTreeProcessor
end
