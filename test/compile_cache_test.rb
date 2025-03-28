# frozen_string_literal: true

require("test_helper")

class CompileCacheTest < Minitest::Test
  include(TmpdirHelper)

  def teardown
    super
    Bootsnap::CompileCache::Native.readonly = false
  end

  def test_compile_option_crc32
    # Just assert that this works.
    Bootsnap::CompileCache::Native.compile_option_crc32 = 0xffffffff
    assert_raises(RangeError) do
      Bootsnap::CompileCache::Native.compile_option_crc32 = 0xffffffff + 1
    end
  end

  def test_coverage_running?
    refute(Bootsnap::CompileCache::Native.coverage_running?)
    require("coverage")
    begin
      Coverage.start
      assert(Bootsnap::CompileCache::Native.coverage_running?)
    ensure
      Coverage.result
    end
  end

  def test_no_write_permission_to_cache
    if RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/
      # Always pass this test on Windows because directories aren't read, only
      # listed. You can restrict the ability to list directory contents on
      # Windows or you can set ACLS on a folder such that it is not allowed to
      # list contents.
      #
      # Since we can't read directories on windows, this specific test doesn't
      # make sense. In addtion we test read-only files in
      # `test_can_open_read_only_cache` so we are covered testing reading
      # read-only files.
      pass
    else
      path = Help.set_file("a.rb", "a = a = 3", 100)
      folder = File.dirname(Help.cache_path(@tmp_dir, path))
      FileUtils.mkdir_p(folder)
      FileUtils.chmod(0o400, folder)
      load(path)
    end
  end

  def test_can_open_read_only_cache
    path = Help.set_file("a.rb", "a = a = 3", 100)
    # Load once to create the cache file
    load(path)
    FileUtils.chmod(0o400, path)
    # Loading again after the file is marked read-only should still succeed
    load(path)
  end

  def test_file_is_only_read_once
    path = Help.set_file("a.rb", "a = a = 3", 100)
    storage = RubyVM::InstructionSequence.compile_file(path).to_binary
    output = RubyVM::InstructionSequence.load_from_binary(storage)
    # This doesn't really *prove* the file is only read once, but
    # it at least asserts the input is only cached once.
    Bootsnap::CompileCache::ISeq.expects(:input_to_storage).times(1).returns(storage)
    Bootsnap::CompileCache::ISeq.expects(:storage_to_output).times(2).returns(output)
    load(path)
    load(path)
  end

  def test_raises_syntax_error
    path = Help.set_file("a.rb", "a = (3", 100)
    assert_raises(SyntaxError) do
      # SyntaxError emits directly to stderr in addition to raising, it seems.
      capture_io { load(path) }
    end
  end

  def test_no_recache_when_mtime_and_size_same
    path = Help.set_file("a.rb", "a = a = 3", 100)
    storage = RubyVM::InstructionSequence.compile_file(path).to_binary
    output = RubyVM::InstructionSequence.load_from_binary(storage)
    Bootsnap::CompileCache::ISeq.expects(:input_to_storage).times(1).returns(storage)
    Bootsnap::CompileCache::ISeq.expects(:storage_to_output).times(2).returns(output)

    load(path)
    Help.set_file(path, "a = a = 4", 100)
    load(path)
  end

  def test_recache_when_mtime_different
    path = Help.set_file("a.rb", "a = a = 3", 100)
    storage = RubyVM::InstructionSequence.compile_file(path).to_binary
    output = RubyVM::InstructionSequence.load_from_binary(storage)
    # Totally lies the second time but that's not the point.
    Bootsnap::CompileCache::ISeq.expects(:input_to_storage).times(2).returns(storage)
    Bootsnap::CompileCache::ISeq.expects(:storage_to_output).times(2).returns(output)

    load(path)
    Help.set_file(path, "a = a = 2", 101)
    load(path)
  end

  def test_recache_when_size_different
    path = Help.set_file("a.rb", "a = a = 3", 100)
    storage = RubyVM::InstructionSequence.compile_file(path).to_binary
    output = RubyVM::InstructionSequence.load_from_binary(storage)
    # Totally lies the second time but that's not the point.
    Bootsnap::CompileCache::ISeq.expects(:input_to_storage).times(2).returns(storage)
    Bootsnap::CompileCache::ISeq.expects(:storage_to_output).times(2).returns(output)

    load(path)
    Help.set_file(path, "a = 33", 100)
    load(path)
  end

  def test_dont_store_cache_after_a_miss_when_readonly
    Bootsnap::CompileCache::Native.readonly = true

    path = Help.set_file("a.rb", "a = a = 3", 100)
    output = RubyVM::InstructionSequence.compile_file(path)
    Bootsnap::CompileCache::ISeq.expects(:input_to_storage).never
    Bootsnap::CompileCache::ISeq.expects(:storage_to_output).never
    Bootsnap::CompileCache::ISeq.expects(:input_to_output).once.returns(output)

    load(path)
  end

  def test_dont_store_cache_after_a_stale_when_readonly
    path = Help.set_file("a.rb", "a = a = 3", 100)
    load(path)

    Bootsnap::CompileCache::Native.readonly = true

    output = RubyVM::InstructionSequence.compile_file(path)
    Bootsnap::CompileCache::ISeq.expects(:input_to_storage).never
    Bootsnap::CompileCache::ISeq.expects(:storage_to_output).once.returns(output)
    Bootsnap::CompileCache::ISeq.expects(:input_to_output).never

    load(path)
  end

  def test_invalid_cache_file
    path = Help.set_file("a.rb", "a = a = 3", 100)
    cp = Help.cache_path("#{@tmp_dir}-iseq", path)
    FileUtils.mkdir_p(File.dirname(cp))
    File.write(cp, "nope")
    load(path)
    assert(File.size(cp) > 32) # cache was overwritten
  end

  def test_instrumentation_hit
    file_path = Help.set_file("a.rb", "a = a = 3", 100)
    load(file_path)

    calls = []
    Bootsnap.instrumentation = ->(event, path) { calls << [event, path] }

    load(file_path)

    assert_equal [], calls
  ensure
    Bootsnap.instrumentation = nil
  end

  def test_instrumentation_miss
    file_path = Help.set_file("a.rb", "a = a = 3", 100)

    calls = []
    Bootsnap.instrumentation = ->(event, path) { calls << [event, path] }

    load(file_path)

    assert_equal [[:miss, "a.rb"]], calls
  ensure
    Bootsnap.instrumentation = nil
  end

  def test_instrumentation_stale
    file_path = Help.set_file("a.rb", "a = a = 3", 100)
    load(file_path)
    file_path = Help.set_file("a.rb", "a = a = 4", 101)

    calls = []
    Bootsnap.instrumentation = ->(event, path) { calls << [event, path] }

    load(file_path)

    assert_equal [[:stale, "a.rb"]], calls
  ensure
    Bootsnap.instrumentation = nil
  end
end
