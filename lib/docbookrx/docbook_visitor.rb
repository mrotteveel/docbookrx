module Docbookrx

class DocbookVisitor
  # transfer node type constants from Nokogiri
  ::Nokogiri::XML::Node.constants.grep(/_NODE$/).each do |sym|
    const_set sym, (::Nokogiri::XML::Node.const_get sym)
  end

  DocbookNs = 'http://docbook.org/ns/docbook'
  XmlNs = 'http://www.w3.org/XML/1998/namespace'
  XlinkNs = 'http://www.w3.org/1999/xlink'
  IndentationRx = /^[[:blank:]]+/
  LeadingSpaceRx = /\A\s/
  LeadingEndlinesRx = /\A\n+ */
  TrailingEndlinesRx = /\n+\z/
  FirstLineIndentRx = /\A[[:blank:]]*/
  WrappedIndentRx = /\n[[:blank:]]*/
  OnlyWhitespaceRx = /\A\s*\Z/m
  PrevAdjacentChar = /\S\Z/
  NextAdjacentChar = /\A\S/

  EmptyString = String.new("")

  EOL = "\n"

  ENTITY_TABLE = {
     169 => '(C)',
     174 => '(R)',
    8201 => ' ', # thin space
    8212 => '--',
    8216 => '\'`',
    8217 => '`\'',
    8220 => '"`',
    8221 => '`"',
    8230 => '...',
    8482 => '(TM)',
    8592 => '<-',
    8594 => '->',
    8656 => '<=',
    8658 => '=>'
  }

  REPLACEMENT_TABLE = {
    ':: ' => '{two-colons} '
  }

  PARA_TAG_NAMES = ['para', 'simpara']

  #COMPLEX_PARA_TAG_NAMES = ['formalpara', 'para']

  ADMONITION_NAMES = ['note', 'tip', 'warning', 'caution', 'important']

  NORMAL_SECTION_NAMES = ['section', 'simplesect', 'sect1', 'sect2', 'sect3', 'sect4', 'sect5']

  SPECIAL_SECTION_NAMES = ['abstract', 'appendix', 'bibliography', 'glossary', 'preface', 'index']

  DOCUMENT_NAMES = ['article', 'book', 'set']

  SECTION_NAMES = DOCUMENT_NAMES + ['chapter', 'part'] + NORMAL_SECTION_NAMES + SPECIAL_SECTION_NAMES

  ANONYMOUS_LITERAL_NAMES = ['abbrev', 'code', 'computeroutput', 'database', 'function', 'literal', 'tag', 'userinput', 'sgmltag']

  NAMED_LITERAL_NAMES = ['acronym', 'application', 'classname', 'command', 'constant', 'date', 'envar', 'exceptionname', 'interfacename', 'methodname', 'option', 'parameter', 'property', 'replaceable', 'type', 'varname']

  LITERAL_NAMES = ANONYMOUS_LITERAL_NAMES + NAMED_LITERAL_NAMES

  FORMATTING_NAMES = LITERAL_NAMES + ['emphasis', 'quote']

  KEYWORD_NAMES = ['package', 'firstterm', 'citetitle', 'errorcode']

  PATH_NAMES = ['directory', 'filename', 'systemitem']

  UI_NAMES = ['guibutton', 'guilabel', 'menuchoice', 'guimenu', 'keycap', 'mousebutton']

  LIST_NAMES = ['simplelist', 'itemizedlist', 'orderedlist', 'variablelist', 'procedure', 'substeps', 'stepalternatives' ]

  IGNORED_NAMES = ['title', 'subtitle', 'toc']

  INLINE_NAMES = FORMATTING_NAMES + KEYWORD_NAMES + PATH_NAMES + ['link', 'ulink', 'xref']

  INLINE_NAMES_AND_TEXT = INLINE_NAMES + ['text']

  attr_reader :lines

  def initialize opts = {}
    @opts = opts
    @lines = []
    @level = 1
    @skip = {}
    @requires_index = false
    @continuation = false
    @adjoin_next = false
    # QUESTION why not handle idprefix and idseparator as attributes (delete on read)?
    @idprefix = opts[:idprefix] || '_'
    @idseparator = opts[:idseparator] || '_'
    @normalize_ids = opts.fetch :normalize_ids, true
    @compat_mode = opts[:compat_mode]
    @attributes = opts[:attributes] || {}
    @sentence_per_line = opts.fetch :sentence_per_line, true
    @preserve_line_wrap = if @sentence_per_line
      false
    else
      opts.fetch :preserve_line_wrap, true
    end
    @delimit_source = opts.fetch :delimit_source, true
    @list_depth = 0
    @in_table = false
    @nested_formatting = []
    @last_added_was_special = false
    @cwd = opts[:cwd] || Dir.pwd
    @outstanding_callouts = {}
  end

  ## Traversal methods

  # Main processor loop
  def visit node
    return if node.type == COMMENT_NODE

    name = node.name
    return if @skip[name]
    visit_method_name = case node.type
    when PI_NODE
      :visit_pi
    when DTD_NODE
      :visit_dtd
    when 17
      :visit_entity_decl
    when ENTITY_REF_NODE
      :visit_entity_ref
    else
      if ADMONITION_NAMES.include? name
        :process_admonition
      elsif LITERAL_NAMES.include? name
        :process_literal
      elsif KEYWORD_NAMES.include? name
        :process_keyword
      elsif PATH_NAMES.include? name
        :process_path
      elsif UI_NAMES.include? name
        :process_ui
      elsif NORMAL_SECTION_NAMES.include? name
        :process_section
      elsif SPECIAL_SECTION_NAMES.include? name
        :process_special_section
      else
        %(visit_#{name}).to_sym
      end
    end
    before_traverse node, visit_method_name if (respond_to? :before_traverse)
    result = if respond_to? visit_method_name
      send visit_method_name, node
    elsif respond_to? :default_visit
      send :default_visit, node
    end
    traverse_children node if result == true
    after_traverse node, visit_method_name if (respond_to? :after_traverse)
  end

  def after
    replace_ifdef_lines
  end

  def traverse_children node, opts = {}
    (opts[:using_elements] ? node.elements : node.children).each do |child|
      child.accept self
    end
  end
  alias :proceed :traverse_children

  ## Text extraction and processing methods

  def text node, unsub = true
    if node
      out = nil;
      if node.is_a? ::Nokogiri::XML::Node
        out = unsub ? reverse_subs(node.text) : node.text
      elsif node.is_a? ::Nokogiri::XML::NodeSet && (first = node.first)
        out = unsub ? reverse_subs(first.text) : first.text
      end
      if ! out.nil? && @in_table
        out.gsub(/\|/, '\|')
      else 
        out
      end
    else
      nil
    end
  end

  def text_at_css node, css, unsub = true
    text (node.at_css css, unsub)
  end

  def format_text node
    if node && (node.is_a? ::Nokogiri::XML::NodeSet)
      node = node.first
    end

    if node.is_a? ::Nokogiri::XML::Node
      append_blank_line
      last_line = lines.length
      proceed node
      @lines.pop(lines.length-last_line+1)
    else
      nil
    end
  end

  def format_text_at_css node, css
    format_text (node.at_css css)
  end

  def entity number
    [number].pack 'U*'
  end

  # Replaces XML entities, and other encoded forms that AsciiDoc automatically
  # applies, with their plain-text equivalents.
  #
  # This method effectively undoes the inline substitutions that AsciiDoc performs.
  #
  # str - The String to processes
  #
  # Examples
  #
  #   reverse_subs "&#169; Acme, Inc."
  #   # => "(C) Acme, Inc."
  #
  # Returns The processed String
  def reverse_subs str
    ENTITY_TABLE.each do |num, text|
      str = str.gsub((entity num), text)
    end
    REPLACEMENT_TABLE.each do |original, replacement|
      str = str.gsub original, replacement
    end
    str
  end

  ## Writer methods

  def append_line line = '', unsub = false
    line = reverse_subs line if !line.empty? && unsub
    @lines << line
  end

  def format_append_line node, suffix=""
    text = format_text node
    line = text.shift(1)[0]
    append_line line + suffix
    lines.concat(text) unless text.empty?
    text
  end

  def format_append_text node, prefix="", suffix=""
    text = format_text node
    line = text.shift(1)[0].strip
    append_text prefix + line + suffix
    lines.concat(text) unless text.empty?
    text
  end

  def append_blank_line
    if @continuation
      @continuation = false
    elsif @adjoin_next
      @adjoin_next = false
    else
      @lines << ''
    end
  end
  alias :start_new_line :append_blank_line

  def append_block_title node, prefix = nil
    if (title_node = (node.at_css '> title') || (node.at_css '> info > title'))
      text = format_text title_node
      title = text.shift(1)[0];
      leading_char = '.'
      # special case for <itemizedlist role="see-also-list"><title>:
      # omit the prefix '.' as we want simple text on a bullet, not a heading
      if node.parent.name == 'itemizedlist' && ((node.attr 'role') == 'see-also-list')
        leading_char = nil
      end
      append_line %(#{leading_char}#{prefix}#{unwrap_text title})
      lines.concat text unless text.empty?
      @adjoin_next = true
      true
    else
      false
    end
  end

  def append_block_role node
    process_xml_id node
    if (role = node.attr('role'))
      append_line %([.#{role}])
      #@adjoin_next = true
      true
    else
      false
    end
  end

  def append_text text, unsub = false
    text = reverse_subs text if unsub
    @lines[-1] = %(#{@lines[-1]}#{text})
  end

  ## Lifecycle callbacks

  def before_traverse node, method
    unless IGNORED_NAMES.include? node.name
      append_ifdef_start_if_condition(node)
    end

    case method.to_s
    when "visit_simplelist", "visit_itemizedlist", "visit_orderedlist", "visit_variablelist",
         "visit_procedure", "visit_substeps", "visit_stepalternatives"
      @list_depth += 1
    when "visit_table", "visit_informaltable", "visit_segmentedlist", "visit_revhistory"
      @in_table = true
    when "visit_emphasis"
      marker = get_emphasis_quote_char node
      @nested_formatting.push marker
    when "process_literal"
      @nested_formatting.push '+'
    end
  end

  def after_traverse node, method
    at_root = (node == node.document.root)
    if at_root
      if @requires_index
        append_blank_line
        append_line 'ifdef::backend-docbook[]'
        append_line '[index]'
        append_line '== Index'
        append_line '// Generated automatically by the DocBook toolchain.'
        append_line 'endif::backend-docbook[]'
      end
    else
      method_name = method.to_s
      case method_name
      when "visit_simplelist", "visit_itemizedlist", "visit_orderedlist", "visit_variablelist",
           "visit_procedure", "visit_substeps", "visit_stepalternatives"
        @list_depth -= 1
        append_blank_line if method_name == "visit_variablelist"
      when "visit_table", "visit_informaltable", "visit_segmentedlist", "visit_revhistory"
        @in_table = false
      when "visit_emphasis", "process_literal"
        @nested_formatting.pop
      end

      @last_added_was_special = false
      case method_name
      when "visit_para", "visit_text", "visit_simpara", 
           "visit_emphasis", "visit_link", "visit_xref"
      else
        unless ( INLINE_NAMES.include? node.name ) || ( ["uri", "ulink", "member"].include? node.name )
          @last_added_was_special = true
        end
      end
    end

    unless IGNORED_NAMES.include? node.name
      append_ifdef_end_if_condition(node)
    end
  end

  ## Node visitor callbacks

  def default_visit node
    warn %(No visitor defined for <#{node.name}>! Skipping.)
    false
  end

  def visit_document node
    true
  end

  def visit_dtd node
    true
  end

  def visit_entity_decl node
    false
  end

  # Convert XML entity refs into attribute refs - e.g. &prodname; -> {prodname}
  def visit_entity_ref node
#    STDERR.puts "visit_entity_ref #{node.name.inspect}"
    append_text %({#{node.name}})
    false
  end

  def ignore node
    false
  end
  # Skip title and subtitle as they're always handled by the parent visitor
  IGNORED_NAMES.each do |name|
    method_name = "visit_#{name}".to_sym
    alias_method method_name, :ignore
  end

  ### Document node (article | book | chapter) & header node (articleinfo | bookinfo | info) visitors

  def visit_book node
    process_doc node
  end

  def visit_article node
    process_doc node
  end

  def visit_info node
    process_info node if DOCUMENT_NAMES.include? node.parent.name
  end
  alias :visit_bookinfo :visit_info
  alias :visit_articleinfo :visit_info

  def visit_chapter node, as = :chapter
    # treat document with <chapter> root element as books
    if node == node.document.root
      @adjoin_next = true
      process_section node do
        append_line ':compat-mode:' if @compat_mode
        append_line ':doctype: book'
        append_line ':sectnums:'
        append_line ':toc: left'
        append_line ':icons: font'
        append_line ':experimental:'
        append_line %(:idprefix: #{@idprefix}).rstrip unless @idprefix == '_'
        append_line %(:idseparator: #{@idseparator}).rstrip unless @idseparator == '_'
        append_line %(:sourcedir: .) unless @attributes.key? 'sourcedir'
        @attributes.each do |name, val|
          append_line %(:#{name}: #{val}).rstrip
        end
      end
    else
      process_section node
    end
  end

  def visit_part node
    visit_chapter node, :part
  end

  def process_xml_id node
    if (id = (resolve_id node, normalize: @normalize_ids))
      if @lines[-1] == "" && @lines[-2] =~ /\.\s+.+/ # xml_id inside list
        append_text %([[#{id}]])
      else
        append_line %([[#{id}]])
      end
    end
  end

  def process_doc node
    process_xml_id node
    # In DocBook 5.0, title is directly inside book/article element
    if (title_node = (node.at_css '> title'))
      title = if title_node
        if (subtitle_node = (node.at_css '> subtitle'))
          title_node.inner_html += %(: #{subtitle_node.inner_html})
        end
        text = format_text title_node
        text.join('').strip.split("\n").map{|s|s.strip}.join(' ')
      end
      append_line %(= #{title})
    end
    @level += 1
    proceed node, :using_elements => true
    @level -= 1
    false
  end

  def process_abstract node
    if (abstract_node = (node.at_css '> abstract'))
      append_line
      append_line '[abstract]'
      append_line '--'
      abstract_node.elements.each do |el|
        append_line
        proceed el
        append_line
      end
      append_text '--'
    end
  end

  def process_info node
    # In DocBook 4.5, title is nested inside info element
    title_node = (node.at_css '> title')
    title = if title_node
      if (subtitle_node = (node.at_css '> subtitle'))
        title_node.inner_html += %(: #{subtitle_node.inner_html})
      end
      text = format_text title_node
      text.join('').strip.split("\n").map{|s|s.strip}.join(' ')
    end
    append_line %(= #{title})

    handle_author node
    date_line = nil
    if (revnumber_node = node.at_css('revhistory revnumber', 'releaseinfo'))
      date_line = %(v#{revnumber_node.text}, ) 
    end
    if (date_node = node.at_css('> date', '> pubdate'))
      append_line %(#{date_line}#{date_node.text})
    end
    if node.name == 'bookinfo' || node.parent.name == 'book' || node.parent.name == 'chapter'
      append_line ':compat-mode:' if @compat_mode
      append_line ':doctype: book'
      append_line ':sectnums:'
      append_line ':toc: left'
      append_line ':icons: font'
      append_line ':experimental:'
    end
    append_line %(:idprefix: #{@idprefix}).rstrip unless @idprefix == '_'
    append_line %(:idseparator: #{@idseparator}).rstrip unless @idseparator == '_'
    @attributes.each do |name, val|
      append_line %(:#{name}: #{val}).rstrip
    end
    process_abstract node
    false
  end

  def handle_author node
    authors = []
    (node.css 'author').each do |author_node|
      # FIXME need to detect DocBook 4.5 vs 5.0 to handle names properly
      author = if (personname_node = (author_node.at_css 'personname'))
        [(text_at_css personname_node, 'firstname'), (text_at_css personname_node, 'surname')].compact * ' '
      else
        [(text_at_css author_node, 'firstname'), (text_at_css author_node, 'surname')].compact * ' '
      end
      if (email_node = (author_node.at_css 'email'))
        author = %(#{author} <#{text email_node}>)
      end
      authors << author unless author.empty?
    end
    append_line (authors * '; ') unless authors.empty?
    false
  end

  def visit_sectioninfo node
    handle_author node
    parent = node.parent
    node_id = resolve_id parent
    title = text_at_css parent, 'title'
    warn %(Possibly incomplete handling of <#{node.name}>: #{title}#{' (' + node_id + ')' if node_id})
  end
  alias :visit_chapterinfo :visit_sectioninfo

  # Very rough first pass at processing xi:include
  def visit_include node
    # QUESTION should we reuse this instance to traverse the new tree?
    href = node.attr 'href'
    include_infile = File.join(@cwd, href)
    include_outfile = include_infile.sub '.xml', '.adoc'
    if ::File.readable? include_infile
      str = ::File.read(include_infile)
      opts = @opts.merge({infile: include_infile})
      dirname = File.dirname(include_infile)
      doc = nil
      Dir.chdir((dirname == ".") ? opts[:cwd] : dirname) do |path|
        doc = Docbookrx.read_xml(str, opts)
      end
      exit 1 unless doc.root
      visitor = self.class.new opts
      doc.root.accept visitor
      result = visitor.lines
      result.shift while result.size > 0 && result.first.empty?
      ::File.open(include_outfile, 'w') {|f| f.write(visitor.lines * EOL) }
    else
      warn %(Include file not readable: #{include_infile})
    end
    append_blank_line
    leveloffset = (@level > 1) ? "leveloffset=#{@level-1}" : ""
    append_line %(include::#{href.sub '.xml', '.adoc'}[#{leveloffset}])
    append_blank_line
    false
  end

  ### Section node visitors

  def visit_bridgehead node
    level = node.attr('renderas').nil? ? @level : node.attr('renderas').sub('sect', '').to_i + 1
    append_blank_line
    append_line '[float]'
    text = format_text node
    title = text.shift(1)[0];
    if (id = (resolve_id node, normalize: @normalize_ids)) && id != (generate_id title)
      append_line %([[#{id}]])
    end
    append_line %(#{'=' * level} #{unwrap_text title})
    lines.concat text unless text.empty?
    false
  end

  def process_special_section node
    if (node.name == 'index')
      append_blank_line
      append_line 'ifdef::backend-docbook,backend-pdf[]'
    end
    process_section node, node.name
    if (node.name == 'index')
      append_line 'endif::backend-docbook,backend-pdf[]'
      @requires_index = false
    end
  end

  def process_section node, special = nil
    append_blank_line
    if special
      append_line ':sectnums!:'
      append_blank_line
      append_line %([#{special}])
    end

    title_node = (node.at_css '> title') || (node.at_css '> info > title')
    title = if title_node
      if (subtitle_node = (node.at_css '> subtitle') || (node.at_css '> info > subtitle'))
        title_node.inner_html += %(: #{subtitle_node.inner_html})
      end
      text = format_text title_node
      # text.shift(1)[0]
      text.join('')
    else
      if special
        special.capitalize
      else
        warn %(No title found for section node: #{node})
        'Unknown Title!'
      end
    end
    if (id = (resolve_id node, normalize: @normalize_ids)) && id != (generate_id title)
      append_line %([[#{id}]])
    end
    append_ifdef_start_if_condition(title_node) if title_node
    # title formatting adds spurious \n, strip leading/trailing ones, replace the others with blanks
    t = title.strip.split("\n").map{|s|s.strip}.join(' ')
    append_line %(#{'=' * @level} #{t})
    # lines.concat(text) unless text.nil? || text.empty?
    append_ifdef_end_if_condition(title_node) if title_node
    yield if block_given?
    if (info_node = node.at_css('> info'))
      process_info info_node
    end
    @level += 1
    proceed node, :using_elements => true
    @level -= 1
    if special
      append_blank_line
      append_line ':sectnums:'
    end
    false
  end

  def generate_id title
    sep = @idseparator
    pre = @idprefix
    # FIXME move regexp to constant
    illegal_sectid_chars = /&(?:[[:alpha:]]+|#[[:digit:]]+|#x[[:alnum:]]+);|\W+?/
    id = %(#{pre}#{title.downcase.gsub(illegal_sectid_chars, sep).tr_s(sep, sep).chomp(sep)})
    if pre.empty? && id.start_with?(sep)
      id = id[1..-1]
      id = id[1..-1] while id.start_with?(sep)
    end
    id
  end

  def resolve_id node, opts = {}
    if (id = node['id'] || node['xml:id'])
      opts[:normalize] ? (normalize_id id) : id
    else
      nil
    end
  end

  # Lowercase id and replace underscores or hyphens with the @idseparator
  # TODO ensure id adheres to @idprefix
  def normalize_id id
    if id
      normalized_id = id.downcase.tr('_-', @idseparator)
      normalized_id = %(#{@idprefix}#{normalized_id}) if @idprefix && !(normalized_id.start_with? @idprefix)
      normalized_id
    else
      nil
    end
  end

  ### Block node visitors

  def visit_formalpara node
    append_blank_line
    append_block_title node
    true
  end

  def visit_para node
    empty_last_line = ! lines.empty? && lines.last.empty?
    append_blank_line unless @continuation
    append_block_role node
    append_blank_line unless empty_last_line
    true
  end

  def visit_simpara node
    empty_last_line = ! lines.empty? && lines.last.empty?
    append_blank_line
    append_block_role node
    append_blank_line unless empty_last_line
    true
  end

  def process_admonition node
    name = node.name
    label = name.upcase
    append_blank_line unless @continuation || (@list_depth > 0)
    if (id = (resolve_id node, normalize: @normalize_ids))
      append_line %([[#{id}]])
    end
    have_title = append_block_title node
    if @list_depth > 0
      append_blank_line if have_title
      local_continuation = @continuation
      append_line %(#{label}: )
      @continuation = true
      proceed node
      @continuation = local_continuation
      append_line '+'
      append_blank_line
      append_blank_line
    else
      append_line %([#{label}])
      append_line '===='
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '===='
    end
    false
  end

  def visit_simplelist node
    list_type = node.attribute('type') rescue nil
    if (list_type && list_type.value != 'vert')
      warn %(Converting simplelist with type=#{list_type.value} to normal list in section '#{text_at_css(get_ancestor(node, 'section'), '> title')}' at #{node.path})
    end
    append_blank_line
    append_block_title node
    append_blank_line if @list_depth == 1
    true
  end

  def get_ancestor node, name
    node.ancestors.each do |ancestor|
      return ancestor if ancestor.name == name
    end
    nil
  end

  def visit_member node
    append_text "* "
    node.children.each do |child|
      child.accept self
    end
    append_line "" if INLINE_NAMES_AND_TEXT.include? node.children.last.name
  end

  def visit_itemizedlist node
    append_blank_line
    append_block_title node
    append_blank_line if @list_depth == 1
    true
  end

  def visit_procedure node
    append_blank_line
    process_xml_id node
    append_block_title node, 'Procedure: '
    visit_orderedlist node
  end

  def visit_substeps node
    visit_orderedlist node
  end

  def visit_stepalternatives node
    visit_orderedlist node
  end

  def visit_orderedlist node
    append_blank_line
    # TODO no title?
    if (numeration = (node.attr 'numeration')) && numeration != 'arabic'
      append_line %([#{numeration}])
    end
    append_blank_line if @list_depth == 1
    true
  end

  def visit_variablelist node
    append_blank_line
    append_block_title node
    @lines.pop if @lines[-1].empty?
    true
  end

  def visit_step node
    visit_listitem node
  end

  # FIXME this method needs cleanup, remove hardcoded logic!
  def visit_listitem node
    @adjoin_next = false
    process_xml_id node
    marker = (node.parent.name == 'orderedlist' || node.parent.name == 'procedure' ? '.' * @list_depth : 
      (node.parent.name == 'stepalternatives' ? 'a.' : '*' * @list_depth))
    if @lines[-1].empty?
      append_text marker
    else
      append_line marker
    end

    first_line = true
    unless node.elements.empty?

      only_text = true
      node.children.each do |child|
        if ! ( ( INLINE_NAMES.include? child.name ) || ( child.name.eql? "text" ) )
          only_text = false
          break
        end
      end

      if only_text
        text = format_text node
        item_text = text.shift(1)[0]

        item_text.split(EOL).each do |line|
          line = line.gsub IndentationRx, ''
          if line.length > 0
            if first_line
              append_text %( #{line})
            else
              append_line %(  #{line})
            end
          end
        end

        unless text.empty?
          append_line '+'
          lines.concat(text)
        end
      else
        node.children.each_with_index do |child,i|
          if ( child.name.eql? "text" ) && child.text.rstrip.empty?
            next
          end

          local_continuation = false
          unless i == 0 || first_line || (child.name == 'literallayout' || child.name == 'itemizedlist' || child.name == 'orderedlist' || child.name == 'procedure')
            append_line '+' unless lines.last == '+'
            @continuation = true
            local_continuation = true
            first_line = true
          end

          if ( PARA_TAG_NAMES.include? child.name ) || ( child.name.eql? "text" )
            text = format_text child
            item_text = text.shift(1)[0]

            item_text = item_text.sub(/\A\+([^\n])/, "+ \n\\1")
            if item_text.empty? && text.empty?
              next
            end

            item_text.split(EOL).each do |line|
              line = line.gsub IndentationRx, ''
              if line.length > 0
                if first_line
                  if local_continuation  # @continuation is reset by format_text
                    append_line %(#{line})
                  else
                    append_text %( #{line})
                  end
                else
                  append_line %(  #{line})
                end
              end
            end

            unless text.empty?
              append_line '+' unless lines.last == "+"
              lines.concat(text)
            end
          else
            if ! INLINE_NAMES.include? child.name
              if first_line && ! local_continuation
                append_text ' {empty}' # necessary to fool asciidoctorj into thinking that this is a listitem
              end
              unless local_continuation || (child.name == 'itemizedlist' || child.name == 'orderedlist' || child.name == 'procedure')
                append_line '+'
              end
              @continuation = false
            end
            child.accept self
            @continuation = true
          end
          first_line = false
        end
      end
    else
      text = format_text node
      item_text = text.shift(1)[0]

      item_text.split(EOL).each do |line|
        line = line.gsub IndentationRx, ''
        if line.length > 0
          if first_line
            append_text %( #{line})
            first_line = false
          else
            append_line %(  #{line})
          end
        end
      end

      unless text.empty?
        append_line '+'
        lines.concat(text)
      end
    end
    @continuation = false
    append_blank_line unless lines.last.empty?

    false
  end

  def visit_varlistentry node
    # FIXME adds an extra blank line before first item
    #append_blank_line unless (previous = node.previous_element) && previous.name == 'title'
    append_blank_line
    process_xml_id node
    text = format_text(node.at_css node, '> term')
    text.each do |text_line| 
      text_line.split(EOL).each_with_index do |line,i|
        line = line.gsub IndentationRx, ''
        if line.length > 0
          if i == 0 
            append_line line
          else 
            append_text ( " " + line )
          end
        end
      end
    end
    append_text ":" + (":" * @list_depth)

    first_line = true
    listitem = node.at_css node, '> listitem'
    listitem.elements.each_with_index do |child,i|
      if ( child.name.eql? "text" ) && child.text.rstrip.empty?
        next
      end
      local_continuation = false
      unless i == 0 || first_line || (child.name == 'literallayout' || child.name == 'screen' || (LIST_NAMES.include? child.name) )
        append_line '+'
#        append_line "+#{child.name.inspect}"
        append_blank_line
        @continuation = true
        local_continuation = true
      end
    
      if ( PARA_TAG_NAMES.include? child.name ) || ( child.name.eql? "text" )
        append_blank_line if i == 0

        text = format_text child
        item_text = text.shift(1)[0]
    
        item_text = item_text.sub(/\A\+([^\n])/, "+\n\\1")
        if item_text.empty? && text.empty?
          next
        end
        item_text.split(EOL).each do |line|
          line = line.gsub IndentationRx, ''
          if line.length > 0
            if first_line
              ((line == "----") || (line == "====")) ? (append_line line) : (append_text line)
              first_line = false
            else
              append_line line
            end
          end
        end
    
        unless text.empty?
          append_line '+' unless lines.last == "+"
          lines.concat(text)
        end
      else
        if ! FORMATTING_NAMES.include? child.name
          unless local_continuation || (child.name == 'literallayout' || (LIST_NAMES.include? child.name) )
            append_line '+'
          end
          @continuation = false
        end
        child.accept self
        @continuation = true
      end
    end

    false
  end

  def visit_glossentry node
    append_blank_line
    if !(previous = node.previous_element) || previous.name != 'glossentry'
      append_line '[glossary]'
    end
    true
  end

  def visit_glossterm node
    format_append_line node, "::"
    false
  end

  def visit_glossdef node
    append_line %(  #{text node.elements.first})
    false
  end

  def visit_cmdsynopsis node
    append_blank_line
    true
  end
  
  def visit_arg node
    process_arg_or_group node
    false
  end
  
  def visit_group node
    process_arg_or_group node
    false
  end
  
  def process_arg_or_group node
    choice = node.attr('choice') || 'opt'
    choice = choice.downcase
    rep = node.attr('rep') || 'norepeat'
    rep = rep.downcase
    # Parse the 'choice' attribute
    openchar, closechar = case choice
    when 'opt'
      [ '[ ', ' ]' ]
    when 'req'
      [ '{ ', ' }' ]
    when 'plain'
      [ '', '' ]
    else
      [ '[ ', ' ]' ]
    end
    # Parse the 'rep' attribute
    repeatchar = case rep
    when 'norepeat'
      ''
    when 'repeat'
      '...'
    else
      ''
    end
    separator = ' | '
    append_text ' '
    append_text openchar
    first = true
    node.children.each do |child|
      if (node.name == 'group') && (child.type == ELEMENT_NODE)
        unless first
          append_text separator
        end
        first = false
        child.accept self
      elsif (node.name == 'arg')
        child.accept self
      end
    end
    append_text repeatchar if repeatchar
    append_text closechar
    false
  end

  def visit_citation node
    append_text %(<<#{node.text}>>)
  end

  def visit_bibliodiv node
    append_blank_line
    append_line '[bibliography]'
    true
  end

  def visit_bibliomisc node
    true
  end

  def visit_bibliomixed node
    append_blank_line
    append_text '- '
    node.children.each do |child|
      if child.name == 'abbrev'
        append_text %([[[#{child.text}]]] )
      elsif child.name == 'title'
        append_text child.text
      else
        child.accept self
      end
    end
    false
  end

  def visit_literallayout node
    append_blank_line
    source_lines = node.text.rstrip.split EOL
    if (source_lines.detect{|line| line.rstrip.empty?})
      append_line '....'
      append_line node.text.rstrip
      append_line '....'
    else
      source_lines.each do |line|
        append_line %(  #{line})
      end
    end
    false
  end

  # process any test inside <screen>
  # check if any child has '----' in text, switch tag to '....' in this case
  # return enclosing tag
  def choose_screen_tag node
    tag = '----'
    node.children.each do |child|
      text = child.text.strip
      next if text.empty?
      source_lines = text.split EOL
      if source_lines.detect {|line| line.match(/^-{4,}/) }
        append_line '[listing]'
        tag = '....'
        break
      end
    end
    append_line tag
    tag
  end

  def visit_screen node
    return false if node.children.empty?
    append_blank_line unless node.parent.name == 'para'
    tag = choose_screen_tag node.children
    first = node.children.first
    node.children.each do |child|
      if child.type == ENTITY_REF_NODE
        s = "{#{child.name}}"
        (child == first) ? append_line(s) : append_text(s)
        next
      end

      text = child.text.strip
      case child.name
      when 'text'
        (child == first) ? append_line(text) : append_text(text)
      when '#cdata-section'
        append_line text
      when 'prompt'
        append_line %(#{text} )
      when 'co' # embedded callout reference
        id = child.attribute_with_ns('id', XmlNs) || child.attribute('id')
        ref = @outstanding_callouts[id.value]
        unless ref
          ref = @outstanding_callouts.size+1
          @outstanding_callouts[id.value] = ref
        end
        append_text " <#{ref}>"
      when 'replaceable'
        (child == first) ? append_line("`#{text}`") : append_text("`#{text}`")
      when 'comment'
          # skip
      when 'command'
        (child == first) ? append_line("#{text} ") : append_text("#{text} ")
      when 'option'
        (child == first) ? append_line("_#{text}_ ") : append_text("_#{text}_ ")
      when 'xref'
        visit_xref child
      else
        warn %(Cannot handle <#{child.name}> within <screen>)
        child.ancestors.each do |parent|
          warn %(  from #{parent.name})
        end
      end
    end
    append_line tag
    false
  end

  def visit_programlisting node
    language = node.attr('language') || node.attr('role') || @attributes['source-language']
    language = %(,#{language.downcase}) if language
    linenums = node.attr('linenumbering') == 'numbered'
    append_blank_line unless node.parent.name == 'para'
    append_line %([source#{language}#{linenums ? ',linenums' : nil}])
    if (first_element = node.elements.first) && first_element.name == 'include'
      append_line '----'
      node.elements.each do |el|
        append_line %(include::{sourcedir}/#{el.attr 'href'}[])
      end
      append_line '----'
    else
      source_lines = node.text.rstrip.split EOL
      if @delimit_source || (source_lines.detect {|line| line.rstrip.empty?})
        append_line '----'
        append_line (source_lines * EOL)
        append_line '----'
      else
        append_line (source_lines * EOL)
      end
    end
    false
  end

  def visit_example node
    process_example node
  end

  def visit_informalexample node
    process_example node
  end

  def process_example node
    append_blank_line
    if (id = (resolve_id node, normalize: @normalize_ids))
      append_line %([[#{id}]])
    end
    append_block_title node
    elements = node.elements.to_a
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && (PARA_TAG_NAMES.include? (child = elements.first).name)
      append_line '[example]'
      # must reset adjoin_next in case block title is placed
      @adjoin_next = false
      format_append_line child
    else
      append_line '===='
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '===='
    end
    false
  end

  # FIXME wrap this up in a process_block method
  def visit_sidebar node
    append_blank_line
    if (id = (resolve_id node, normalize: @normalize_ids))
      append_line %([[#{id}]])
    end
    append_block_title node 
    elements = node.elements.to_a
    # TODO make skipping title a part of append_block_title perhaps?
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && PARA_TAG_NAMES.include?((child = elements.first).name)
      append_line '[sidebar]'
      format_append_line child
    else
      append_line '****'
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '****'
    end
    false
  end

  def visit_blockquote node
    append_blank_line
    append_block_title node 
    elements = node.elements.to_a
    # TODO make skipping title a part of append_block_title perhaps?
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && PARA_TAG_NAMES.include?((child = elements.first).name)
      append_line '[quote]'
      format_append_line child
    else
      append_line '____'
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '____'
    end
    false
  end

  def visit_table node
    append_blank_line
    process_xml_id node
    append_block_title node
    process_table node
    false
  end

  def visit_informaltable node
    append_blank_line
    process_xml_id node
    process_table node
    false
  end

  # Always converts to a table
  def visit_segmentedlist node
    append_blank_line
    process_xml_id node
    numheaders = 0
    node.css('> segtitle').each do |segtitle|
      numheaders += 1
    end
    cols = ('1' * numheaders).split('')
    append_line %([%autowidth,cols="#{cols * ','}", options="header", frame="none", grid="none", role="segmentedlist"])
    append_line '|==='
    node.css('> segtitle').each do |segtitle|
      append_line '|'
      proceed segtitle
    end
    node.css('> seglistitem').each do |row|
      append_blank_line
      row.css('> seg').each do |cell|
        append_line 'a|'
        proceed cell
      end
    end
    append_line '|==='
    false
  end

  # Processes a revision history (restricted to what is used in Firebird docs)
  def visit_revhistory node
    append_blank_line
    process_xml_id node
    append_line %([%autowidth, width="100%", cols="4", options="header", frame="none", grid="none", role="revhistory"])
    append_line '|==='
    append_line '4+|Revision History'
    node.css('> revision').each do |revision|
      append_blank_line
      if (revnumber = text_at_css revision, '> revnumber')
        append_line %(|#{revnumber})
      else 
        append_line '|{nbsp}'
      end
      if (date = text_at_css revision, '> date')
        append_line %(|#{date})
      else 
        append_line '|{nbsp}'
      end
      if (authorinitials = text_at_css revision, '> authorinitials')
        append_line %(|#{authorinitials})
      else
        append_line '|{nbsp}'
      end
      if (revremark = text_at_css revision, '> revremark')
        append_line %{|#{revremark}}
      elsif (revdescription_node = revision.at_css '> revdescription')
        append_line 'a|'
        proceed revdescription_node
      else
        append_line '|{nbsp}'
      end
    end
    append_line '|==='
    false
  end

  # check for horizontal span of entry
  # return [namest,nameend] of entry
  def entry_hspan node
    namest = node.attribute('namest').value rescue nil
    nameend = node.attribute('nameend').value rescue nil
    [namest, nameend]
  end

  # check for vertical span of entry
  def entry_vspan node
    node.attribute("morerows").value.to_i rescue nil
  end

  def find_colname_index colspecs, name
    colspecs.find_index do |colspec|
      v = colspec.attribute('colname').value rescue nil
      v == name
    end
  end

  def compute_hspan colspecs, entry
    nstart, nend = entry_hspan entry
    if nstart && nend
      # if there's a span given, compute the index difference
      sindex = find_colname_index colspecs, nstart
      eindex = find_colname_index colspecs, nend
      if sindex && eindex
        return (eindex - sindex) + 1
      else
        warn %('namest' #{nstart} not found in <colspec>) unless nstart
        warn %('nameend' #{nend} not found in <colspec>) unless nend
      end
    end
    return 1
  end

  # compute prefix for row entry
  # combinings spans and alignments
  def cell_prefix colspecs, cell
    align = cell.attribute("align").value rescue nil
    as = case align
           when "left"
             "<"
           when "center"
             "^"
           when "right"
             ">"
           else
             ""
         end
    valign = cell.attribute("valign").value rescue nil
    vas = case valign
            when "top"
              ".<"
            when "middle"
              ".^"
            when "bottom"
              ".>"
            else
              ""
            end
    vspan = entry_vspan(cell)
    vs = vspan ? ".#{vspan+1}" : ""
    hspan = compute_hspan(colspecs, cell)
    hs = (hspan > 1) ? "#{hspan}" : ""
    span = (hs.empty? && vs.empty?) ? "" : "#{hs}#{vs}+"
    "#{span}#{as}#{vas}"
  end

  def process_table node
    tgroup = node.at_css '> tgroup'
    numcols = tgroup.attr('cols').to_i
    colspecs = tgroup.css '> colspec'
    head = tgroup.at_css '> thead'
    title = " \'" +
      ((title_node = (node.at_css '> title')).nil? ?
        "" : title_node.children[0].text) +
      "\'"
    unless colspecs.empty? || (colspecs.size == numcols)
      warn %(#{numcols} columns specified in table#{title}, but only #{colspecs.size} colspecs)
    end
    unless head.nil?
      numheadrows = head.css('> row').size
      if (numheadrows > 1)
        warn %(#{numheadrows} rows in header specified in table#{title} in section '#{text_at_css(get_ancestor(node, 'section'), '> title')}' at #{node.path}, only first row will be written out)
      end
      if (head_row = (tgroup.at_css '> thead > row'))
        numheaders = 0
        head_row.css('> entry').each do |entry|
          numheaders += compute_hspan colspecs, entry
        end
        if numheaders != numcols
          warn %(#{numcols} columns specified in table#{title}, but only #{numheaders} headers)
        end
      end
    end
    cols = ('1' * numcols).split('')
    body = tgroup.at_css '> tbody'
    unless body.nil?
      row1 = body.at_css '> row'
      row1_cells = row1.elements
      numcols.times do |i|
        next if (row1_cells[i].nil? || !(element = row1_cells[i].elements.first))
        case element.name
        when 'literallayout'
          cols[i] = %(#{cols[i]}*l)
        end
      end
    end

    if (frame = node.attr('frame'))
      frame = %(, frame="#{frame}")
    else
      frame = nil
    end
    options = []
    if head
      options << 'header'
    end
    if (foot = tgroup.at_css '> tfoot')
      options << 'footer'
    end
    options = (options.empty? ? nil : %(, options="#{options * ','}"))
    append_line %([cols="#{cols * ','}"#{frame}#{options}])
    append_line '|==='
    if head_row
      (head_row.css '> entry').each do |cell|
        pf = cell_prefix colspecs, cell
        append_line %(#{pf}| #{text cell})
      end
      append_blank_line
    end
    (tgroup.css '> tbody > row').each do |row|
      append_ifdef_start_if_condition(row)
      append_blank_line
      row.elements.each do |cell|
        pf = cell_prefix colspecs, cell
        case cell.name
        when 'literallayout'
          append_line "#{pf}|#{text cell}"
        else
          append_line "#{pf}|"
          proceed cell
        end
      end
      append_ifdef_end_if_condition(row)
    end
    if foot
      (foot.css '> row > entry').each do |cell|
        pf = cell_prefix colspecs, cell
        append_line %(#{pf}| #{text cell})
      end
    end
    append_line '|==='
    false
  end

  ### Inline node visitors

  def strip_whitespace text
    wsMatch = text.match(OnlyWhitespaceRx)
    if wsMatch != nil && wsMatch.size > 0
      return EmptyString
    end
    res = text.gsub(LeadingEndlinesRx, '')
      .gsub(WrappedIndentRx, @preserve_line_wrap ? EOL : ' ')
      .gsub(TrailingEndlinesRx, '')
    res
  end

  def visit_superscript node
    format_append_text node, '^', '^'
  end

  def visit_subscript node
    format_append_text node, '~', '~'
  end

  def visit_text node
    in_para = PARA_TAG_NAMES.include?(node.parent.name) || node.parent.name == 'phrase'
    # drop text if empty unless we're processing a paragraph
    unless node.text.rstrip.empty?
      text = node.text
      if in_para
        leading_space_match = text.match LeadingSpaceRx
        # strips surrounding endlines and indentation on normal paragraphs
        # TODO factor out this whitespace processing
        text = strip_whitespace text
        is_first = !node.previous_element
        if is_first
          text = text.lstrip
        elsif leading_space_match && !!(text !~ LeadingSpaceRx)
          if @lines[-1] == "----" || @lines[-1] == "====" 
            text = %(#{leading_space_match[0]}#{text})
          elsif (node_prev = node.previous) &&
                ! ( node_prev.name == "para" || node_prev.name == "text" ) &&
                ( (lines.last.end_with? " ") || (lines.last.end_with? "\n") || lines.last.empty? )
            # no leading space before text
          else
            text = %( #{text})
          end
        end

        # FIXME sentence-per-line logic should be applied at paragraph block level only
        if @sentence_per_line
          # FIXME move regexp to constant
          text = text.gsub(/(?:^|\b)\.[[:blank:]]+(?!\Z)/, %(.#{EOL}))
        end
      end
      # escape |'s in table cell text
      if @in_table
        text = text.gsub(/\|/, '\|')
      end
      if ! @nested_formatting.empty?
        if text.start_with? '_','*','+','`','#'
          text = '\\' + text
        end
      end
      if ( @lines[-1].empty? ) && ( text.start_with? '.' )
        text = text.sub( /\A(\.+)/, "$$\\1$$" )
      end
      if @last_added_was_special
        readd_space = text.end_with? " ","\n"
        text = "\n" + text.rstrip
        text = text + " " if readd_space
      end

      append_text text, true
    end
    false
  end

  def visit_anchor node
    return false if node.parent.name.start_with? 'biblio'
    id = resolve_id node, normalize: @normalize_ids
    append_text %([[#{id}]])
    false
  end

  def visit_link node
    if node.attr 'linkend'
      visit_xref node
    else
      visit_uri node
    end
    false
  end

  def visit_uri node
    url = if node.name == 'ulink'
      node.attr 'url'
    else
      href = (node.attribute_with_ns 'href', XlinkNs)
      if (href)
        href.value
      else
        node.text
      end
    end
    prefix = 'link:'
    if url.start_with?('http://') || url.start_with?('https://')
      prefix = nil
    end
    label = text node
    if label.empty? || url == label
      if (ref = @attributes.key(url))
        url = %({#{ref}})
      end
      append_text %(#{prefix}#{url})
    else
      if (ref = @attributes.key(url))
        url = %({#{ref}})
      end
      append_text %(#{prefix}#{url}[#{label}])
    end
    false
  end

  alias :visit_ulink :visit_uri

  # QUESTION detect bibliography reference and autogen label?
  def visit_xref node
    linkend = node.attr 'linkend'
    id = @normalize_ids ? (normalize_id linkend) : linkend
    text = format_text node
    label = text.shift(1)[0]
    if label.empty?
      append_text %(<<#{id}>>)
    else
      append_text %(<<#{id},#{lazy_quote label}>>)
    end
    lines.concat(text) unless text.empty?
    false
  end

  def visit_phrase node
    text = format_text node
    phText = text.shift(1)[0]
    if node.attr 'role'
      # FIXME for now, double up the marks to be sure we catch it
      append_text %([#{node.attr 'role'}]###{phText}##)
    else
      append_text %(#{phText})
    end
    lines.concat(text) unless text.empty?
    false
  end

  def visit_foreignphrase node
    format_append_text node
  end

  alias :visit_attribution :proceed

  def visit_quote node
    format_append_text node, '"`', '`"'
  end

  def visit_emphasis node
    quote_char = get_emphasis_quote_char node
    times = (adjacent_character node) ? 2 : 1;
    
    format_append_text node, (quote_char * times), (quote_char * times)
    false
  end

  def get_emphasis_quote_char node
    roleAttr = node.attr('role')
    case roleAttr
    when 'strong', 'bold'
      '*'
    when 'marked'
      '#'
    else
      '_'
    end
  end

  def adjacent_character node
    if @nested_formatting.length > 1
      true
    elsif ((prev_node = node.previous) && prev_node.type == TEXT_NODE && PrevAdjacentChar =~ prev_node.text) ||
          ((next_node = node.next) && next_node.type == TEXT_NODE && NextAdjacentChar =~ next_node.text)
      true
    elsif (prev_node = node.previous) && ! prev_node.children.empty? && 
          ( FORMATTING_NAMES.include? prev_node.name ) &&
          (adj_child = prev_node.children[0]).type == TEXT_NODE && PrevAdjacentChar =~ adj_child.text
      true
    elsif (next_node = node.next) && (! next_node.children.empty? ) && 
          ( FORMATTING_NAMES.include? next_node.name ) &&
          (adj_child = next_node.children[0]).type == TEXT_NODE && NextAdjacentChar =~ adj_child.text
      true
    elsif (! lines.last.empty?) && (! lines.last.end_with? "\s","\n","\t","\f")
      true
    else
      false
    end
  end

  def visit_remark node
    append_blank_line
    append_text %(ifdef::showremarks[])
    append_blank_line
    format_append_text node, "#", "#"
    append_blank_line
    append_text %(endif::showremarks[])
    append_blank_line
    false
  end

  def visit_trademark node
    format_append_text node, "#", "(TM)"
    false
  end

  def visit_prompt node
    # TODO remove the space left by the prompt
    #@lines.last.chop!
    false
  end

  def process_path node
    case node.name
    when 'systemitem'
      role = node['class'] || node.name
    else
      role = 'path'
    end
    #role = case (name = node.name)
    #when 'directory'
    #  'path'
    #when 'filename'
    #  'path'
    #else
    #  name
    #end
    append_text %([#{role}]``#{node.text}``)
    false
  end

  # replace "...\n  ..." with "... ..."
  def menu_normalize str
    str.split("\n").map{|s| s.strip}.join(" ")
  end

  def process_ui node
    name = node.name
    if name == 'guilabel' && (next_node = node.next) &&
        next_node.type == ENTITY_REF_NODE && ['rarr', 'gt'].include?(next_node.name)
      name = 'guimenu'
    end

    case name
    # ex. <menuchoice><guimenu>System</guimenu><guisubmenu>Documentation</guisubmenu></menuchoice>
    when 'menuchoice'
      items = node.children.map {|n|
        if (n.type == ELEMENT_NODE) && ['guimenu', 'guisubmenu', 'guimenuitem'].include?(n.name)
          n.instance_variable_set :@skip, true
          n.text
        end
      }.compact
      append_text %(menu:#{items[0]}[#{items[1..-1] * ' > '}])
    # ex. <guimenu>Files</guimenu> (top-level)
    when 'guimenu'
      append_text %(menu:#{menu_normalize(node.text)}[])
      # QUESTION when is this needed??
      #items = []
      #while (node = node.next) && ((node.type == ENTITY_REF_NODE && ['rarr', 'gt'].include?(node.name)) ||
      #  (node.type == ELEMENT_NODE && ['guimenu', 'guilabel'].include?(node.name)))
      #  if node.type == ELEMENT_NODE
      #    items << node.text
      #  end
      #  node.instance_variable_set :@skip, true
      #end
      #append_text %([#{items * ' > '}]) 
    when 'guibutton'
      append_text %(btn:[#{menu_normalize(node.text)}])
    when 'guilabel'
      append_text %([label]##{node.text}#)
    when 'keycap'
      function = node.attribute("function").value rescue nil
      case function
      when 'control'
        append_text %(kbd:[Ctrl])
      when 'shift'
        append_text %(kbd:[Shift])
      when 'alt'
        append_text %(kbd:[Alt])
      when 'enter'
        append_text %(kbd:[Enter])
      when nil
        # skip
      else
        warn "Unhandled <keycap> function #{function.inspect}"
      end
      unless (t = node.text).empty?
        append_text %(kbd:[#{t}])
      end
    when 'mousebutton'
      append_text %(mouse:[#{node.text}])
    end
    false
  end

  def process_keyword node
    role, char = case (name = node.name)
    when 'firstterm'
      ['term', '_']
    when 'citetitle'
      ['ref', '_']
    else
      [name, '#']
    end
    append_text %([#{role}]#{char}#{node.text}#{char})
    false
  end

  def process_literal node
    name = node.name
    unless ANONYMOUS_LITERAL_NAMES.include? name
      shortname = case name
      when 'envar'
        'var'
      when 'application'
        'app'
      else
        name.sub 'name', ''
      end
      append_text %([#{shortname}])
    end
  
    times = (adjacent_character node) ? 2 : 1;
    if (node.parent.name == 'quote')
      times = 2
    end
    literal_char = ('`' * times)
    other_format_start = other_format_end = ''

    if @nested_formatting.length > 1 
      emphasis = false
      bold = false
      for i in 0..@nested_formatting.length-2
        case @nested_formatting[i]
        when '_'
          emphasis = true
        when '*'
          bold = true
        end
        if emphasis && bold
          break
        end
      end
  
      if emphasis && bold
        other_format_start = "**__"
        other_format_end = "__**"
      elsif emphasis
        other_format_start = other_format_end = "__"
      elsif bold
        other_format_start = other_format_end = "**"
      end
    end


    format_append_text node, literal_char + other_format_start, other_format_end + literal_char

    false 
  end

  alias :visit_guiicon :proceed

  def imagedata_attrs node
    imagedata = src = nil
    node.css('imageobject').each do |io|
      id = io.at_css('imagedata')
      src = id.attr('fileref')
      unless src.end_with? '.svg' # prefer .svg files
        next if io.attr('role') == "fo" # skip role=fo
      end
      imagedata = id
      break
    end
    return nil unless imagedata
    width = imagedata.attr('width')
    width_s = (width.nil?) ? "" : "scaledwidth=#{width}"
    alt = text_at_css node, 'textobject phrase'
    generated_alt = ::File.basename(src)[0...-(::File.extname(src).length)]
    alt = nil if alt && alt == generated_alt
    lqa = (lazy_quote alt) || ""
    sep = (lqa.empty? || width_s.empty?) ? "" : ","
    "#{src}[#{lqa}#{sep}#{width_s}]"
  end

  def visit_inlinemediaobject node
    append_text %(image:#{imagedata_attrs node})
    false
  end

  def visit_mediaobject node
    unless node.attr('role') == "fo" # skip role=fo
      visit_figure node
    end
  end

  # FIXME share logic w/ visit_inlinemediaobject, which is the same here except no block_title and uses append_text, not append_line
  def visit_figure node
    
    if node.name != 'informalfigure'
      append_blank_line
      append_block_title node
      if id = resolve_id(node, normalize: @normalize_ids)
        append_text %( [[#{id}]])
      end
      append_blank_line
    else
      #if node.name == 'informalfigure'
#      append_block_title node
      append_blank_line
    end
    if (attrs = imagedata_attrs(node))
      output = %(image::#{attrs})
      if node.parent.name == 'listitem'
        append_line output
      else
        append_blank_line
        append_line output
        append_blank_line
      end
    else
      warn %(Unknown mediaobject <#{node.elements.first.name}>! Skipping.)
    end
    false
  end
  alias :visit_informalfigure :visit_figure

  def visit_footnote node
    append_text %(footnote:[#{(text_at_css node, '> para', '> simpara').strip}])
    # FIXME not sure a blank line is always appropriate
    #append_blank_line
    false
  end

  def visit_funcsynopsis node
    append_blank_line unless node.parent.name == 'para'
    append_line '[source,c]'
    append_line '----'

    if (info = node.at_xpath 'db:funcsynopsisinfo', 'db': DocbookNs)
      info.text.strip.each_line do |line|
        append_line line.strip
      end
      append_blank_line
    end

    if (prototype = node.at_xpath 'db:funcprototype', 'db': DocbookNs)
      indent = 0
      first = true
      append_blank_line
      if (funcdef = prototype.at_xpath 'db:funcdef', 'db': DocbookNs)
        append_text funcdef.text
        indent = funcdef.text.length + 2
      end

      (prototype.xpath 'db:paramdef', 'db': DocbookNs).each do |paramdef|
        if first
          append_text ' ('
          first = false
        else
          append_text ','
          append_line ' ' * indent
        end
        append_text paramdef.text.sub(/\n.*/m, '')
        if (param = paramdef.at_xpath 'db:funcparams', 'db': DocbookNs)
          append_text %[ (#{param.text})]
        end
      end

      if (varargs = prototype.at_xpath 'db:varargs', 'db': DocbookNs)
        if first
          append_text ' ('
          first = false
        else
          append_text ','
          append_line ' ' * indent
        end
        append_text %(#{varargs.text}...)
      end

      append_text(first ? ' (void);' : ');')
    end

    append_line '----'
  end

  # FIXME blank lines showing up between adjacent index terms
  def visit_indexterm node
    previous_skipped = false
    if @skip.has_key? :indexterm
      skip_count = @skip[:indexterm]
      if skip_count > 0
        @skip[:indexterm] -= 1
        return false
      else
        @skip.delete :indexterm
        previous_skipped = true
      end
    end

    @requires_index = true
    entries = [(text_at_css node, 'primary'), (text_at_css node, 'secondary'), (text_at_css node, 'tertiary')].compact
    #if previous_skipped && (previous = node.previous_element) && previous.name == 'indexterm'
    #  append_blank_line
    #end
    @skip[:indexterm] = entries.size - 1 if entries.size > 1
    # append_blank_line unless @lines[-1].empty?
    append_line %[(((#{entries * ','})))]
    # Only if next word matches the index term do we use double-bracket form
    #if entries.size == 1
    #  append_text %[((#{entries.first}))]
    #else
    #  @skip[:indexterm] = entries.size - 1
    #  append_text %[(((#{entries * ','})))]
    #end
    false
  end

  def visit_pi node
    case node.name
    when 'asciidoc-br'
      append_text ' +'
    when 'asciidoc-hr'
      # <?asciidoc-hr?> will be wrapped in a para/simpara
      append_text '\'' * 3
    end
    false
  end

  def visit_qandaset node
    first = true
    # might be wrapped in 'qandadiv'
    node = node.at_xpath('db:qandadiv', 'db': DocbookNs) || node.at_xpath('qandadiv') || node
    node.elements.to_a.each do |element|
        if element.name == 'title'
          append_line ".#{element.text}"
          append_blank_line
        end
        if first
          append_line '[qanda]'
          first = false
        end
        if element.name == 'qandaentry'
          id = resolve_id element, normalize: @normalize_ids
          question = element.at_xpath('question/para') || element.at_xpath('db:question/db:para', 'db': DocbookNs)
          if (question)
            append_line %([[#{id}]]) if id
            format_append_line question, "::"
            answer = element.at_xpath('answer') || element.at_xpath('db:answer', 'db': DocbookNs)
            if (answer)
              first = true
              answer.children.each_with_index do |child, i|
                unless child.text.rstrip.empty?
                  unless first
                    append_line '+'
                    @continuation = true
                  end
                  first = nil
                  child.accept self
                end
              end
              @continuation = false
            else
              warn %(Missing answer in quandaset!)
            end
            append_blank_line
          else
            warn %(Missing question in quandaset! Skipping.)
          end
        end
    end
  end

  # <set> ... <xi:include ...> </set>
  def visit_set node
    node.elements.to_a.each do |element|
      visit element
    end
  end

  # <keycombo> ... <keycap>...</keycap> </keycombo>
  def visit_keycombo node
    append_text "kbd:["
    follower = ""
    separator = ""
    appender = "]"
    node.elements.each do |keycap|
      if keycap.name == "keycap"
        if appender.empty?
          append_text "#{follower}kbd:["
          follower = ""
          separator = ""
          appender = "]"
        end
        append_text "#{separator}#{keycap.text}"
      elsif keycap.name == "mousebutton"
        append_text "#{appender}-#{keycap.text}"
        appender = ""
        follower = "-"
      else
        warn %(keycombo not followed by keycap but #{keycap.name.inspect}. Skipping.)
      end
      separator = "+" 
    end
    append_text appender
  end

  # <email>foo@bar.org</email>
  def visit_email node
    append_line "mailto:#{node.text}[<#{node.text}>]"
  end

  # <calloutlist><callout arearefs="...">...</callout></calloutlist>
  # see https://github.com/asciidoctor/asciidoctor/issues/1077
  def visit_calloutlist node
    node.elements.each do |element|
      unless (element.name == "callout")
        warn %(Expected <callout> after <calloutlist> but got <#{element.name}>. Ignoring.)
        next
      end
      arearefs = element.attribute('arearefs')
      ref = @outstanding_callouts[arearefs.value]
      unless ref
        warn %(<callout> references undefined #{arearefs.value}, ignoring)
      end
      visit_callout element, ref
    end
  end
  def visit_callout node, ref=nil
    unless node.parent.name == "calloutlist"
      warn %(callout outside of calloutlist)
    end
    node.elements.each do |element|
      unless PARA_TAG_NAMES.include? element.name
        warn %(Unhandled <callout> child: <#{element.name}>)
        next
      end
      element.children.each do |child|
        case child.name
        when 'text'
          if ref
            append_line "<#{ref}>#{child.text}"
          else
            append_line child.text
          end
          ref = nil
        else
          visit child
        end
      end
    end
  end

  def visit_keycode node
    append_text "keycode:[#{node.text}]"
  end

  def lazy_quote text, seek = ','
    if text && (text.include? seek)
      %("#{text}")
    else
      text
    end
  end

  def unwrap_text text
    text.gsub WrappedIndentRx, ''
  end

  def element_with_condition? node
    node.type == ELEMENT_NODE && node.attr('condition')
  end

  def append_ifdef_if_condition node
    return unless element_with_condition?(node)
    condition = node.attr('condition')
    yield condition
  end

  def append_ifdef_start_if_condition node
    append_ifdef_if_condition node do |condition|
      append_line "ifdef::#{condition}[]"
    end
  end

  def append_ifdef_end_if_condition node
    append_ifdef_if_condition node do |condition|
      append_line "endif::#{condition}[]"
    end
  end

  def replace_ifdef_lines
    out_lines = []
    @lines.each do |line|
      if (data = line.match(/^((ifdef|endif)::.+?\[\])(.+)$/))
        # data[1]: "(ifdef|endif)::something[]"
        out_lines << data[1]
        # data[3]: a string after "[]"
        out_lines << data[3]
      else
        out_lines << line
      end
    end
    @lines = out_lines
  end
end
end