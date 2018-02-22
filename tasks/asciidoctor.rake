dirname = File.dirname(__FILE__)
testsuite = File.expand_path(File.join(dirname, "..", "testsuite"))

task :asciidoctor => [:docbookrx, :adoc_docbook, :images, :adocxml_html, :adocxml_pdf]

# use asciidoctor to convert .adoc to .xml
task :adoc_docbook do
  `asciidoctor -b docbook5\
  -d book\
  -D #{File.join(testsuite, "asciidoctor", "xml")}\
  #{File.join(testsuite, "xml", "MAIN-set.adoc")}`
end

# copy all images to local-subdir
task :images do
  require 'find'
  sourcedir = File.join(testsuite, "images")
  destdir = File.join(testsuite, "asciidoctor","build","MAIN-set","html","MAIN-set", "images")
  Dir.mkdir(destdir) rescue nil
  Find.find(sourcedir) do |path|
    next unless path =~ /\.jpg/
    `cp #{path} #{destdir}`
  end
end

# convert adoc-generated-xml to html
task :adocxml_html do
  `daps -m #{File.join(testsuite, "asciidoctor", "xml", "MAIN-set.xml")} --styleroot /usr/share/xml/docbook/stylesheet/suse2013-ns html`
  puts "Asciidoc generated HTML: testsuite/asciidoctor/build/MAIN-set/html/MAIN-set/index.html"
end

# convert adoc-generated-xml to pdf
task :adocxml_pdf do
  `daps -m #{File.join(testsuite, "asciidoctor", "xml", "MAIN-set.xml")} --styleroot /usr/share/xml/docbook/stylesheet/suse2013-ns pdf`
  puts "Asciidoc generated PDF: testsuite/asciidoctor/build/MAIN-set/MAIN-set_color_en.pdf"
end
