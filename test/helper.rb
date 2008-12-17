require 'rubygems'
require 'test/unit'
require 'mocha'

require 'smqueue'
require 'rstomp'

module ReadableTestNames
  def test(name, &block)
    test_name = "test_#{name.gsub(/\s+/,'_')}".to_sym
    defined = instance_method(test_name) rescue false
    raise "#{test_name} is already defined in #{self}" if defined
    if block_given?
      define_method(test_name, &block)
    else
      define_method(test_name) do
        flunk "No implementation provided for #{name}"
      end
    end
  end
end

Test::Unit::TestCase.send(:extend, ReadableTestNames)