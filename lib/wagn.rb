require File.dirname(__FILE__) + '/wagn/version'
require File.dirname(__FILE__) + '/wagn/exceptions'
require File.dirname(__FILE__) + '/ruby_ext'
require File.dirname(__FILE__) + '/rails_ext'
require File.dirname(__FILE__) + '/cardname'


COMPRESSED_JS = 'wagn_cmp.js'
JAVASCRIPT_FILES = %w{
  prototype.js
  effects.js 
  controls.js
  application.js
  Wagn.js

  Wikiwyg.js
  Wikiwyg/Toolbar.js
  Wikiwyg/Wysiwyg.js
  Wikiwyg/Wikitext.js
  Wikiwyg/Preview.js
  Wikiwyg/Util.js
  Wikiwyg/HTML.js
  Wikiwyg/Debug.js
  Wagn/Wikiwyg.js
  Wagn/LinkEditor.js
  Wagn/Lister.js

  calendar.js

}


CRAZY_FILES = %{
  window.js
  builder.js
  
  
  Wagn/Card.js
  Wagn/Editor.js
}

js_dir = "#{RAILS_ROOT}/public/javascripts"
Dir["#{js_dir}/Wagn/*/*.js"].collect do |file|
  #JAVASCRIPT_FILES << 'Wagn/Editor/' + Pathname.new(file).basename.to_s
end
