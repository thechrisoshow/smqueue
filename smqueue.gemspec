Gem::Specification.new do |s|
  s.name = %q{smqueue}
  s.version = "0.1.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Sean O'Halpin"]
  s.date = %q{2009-01-05}
  s.description = %q{Implements a simple protocol for using message queues, with adapters for ActiveMQ, Spread and stdio (for testing).  This is a bare-bones release to share with my colleagues - apologies for the lack of documentation and tests.}
  s.email = %q{sean.ohalpin@gmail.com}
  s.extra_rdoc_files = ["History.txt", "README.txt"]
  s.files = ["History.txt", "Manifest.txt", "README.txt", "Rakefile", "lib/rstomp.rb", "lib/smqueue.rb", "lib/smqueue/adapters/spread.rb", "lib/smqueue/adapters/stdio.rb", "lib/smqueue/adapters/stomp.rb", "tasks/ann.rake", "tasks/bones.rake", "tasks/gem.rake", "tasks/git.rake", "tasks/manifest.rake", "tasks/notes.rake", "tasks/post_load.rake", "tasks/rdoc.rake", "tasks/rubyforge.rake", "tasks/setup.rb", "tasks/spec.rake", "tasks/svn.rake", "tasks/test.rake", "test/test_rstomp_connection.rb"]
  s.has_rdoc = true
  s.homepage = %q{http://github.com/seanohalpin/smqueue}
  s.rdoc_options = ["--main", "README.txt"]
  s.require_paths = ["lib"]
  s.rubyforge_project = %q{smqueue}
  s.rubygems_version = %q{1.3.1}
  s.summary = %q{Implements a simple protocol for using message queues, with adapters for ActiveMQ, Spread and stdio (for testing)}
  s.test_files = ["test/test_rstomp_connection.rb"]

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 2

    if Gem::Version.new(Gem::RubyGemsVersion) >= Gem::Version.new('1.2.0') then
      s.add_runtime_dependency(%q<doodle>, [">= 0.1.9"])
      s.add_development_dependency(%q<bones>, [">= 2.1.0"])
    else
      s.add_dependency(%q<doodle>, [">= 0.1.9"])
      s.add_dependency(%q<bones>, [">= 2.1.0"])
    end
  else
    s.add_dependency(%q<doodle>, [">= 0.1.9"])
    s.add_dependency(%q<bones>, [">= 2.1.0"])
  end
end
