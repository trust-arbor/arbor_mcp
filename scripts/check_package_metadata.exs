# Run without loading any package dependencies. Hex metadata is Erlang terms,
# so consult it rather than applying a partial text parser.
Mix.start()
Mix.env(:prod)

projects =
  for directory <- System.argv() do
    {:ok, terms} =
      :file.consult(String.to_charlist(Path.join(directory, ".archive-metadata.config")))

    metadata = Map.new(terms)
    app = String.to_atom(metadata["app"])

    Mix.Project.in_project(app, directory, fn _ ->
      config = Mix.Project.config()
      version = config[:version]
      source = File.read!("mix.exs")
      [[_matched, literal]] = Regex.scan(~r/@version "([^"]+)"/, source)
      true = version == literal and version == metadata["version"]

      expected_version =
        System.get_env("ARCHIVE_EXPECTED_VERSION_#{String.upcase(Atom.to_string(app))}") ||
          System.fetch_env!("ARCHIVE_EXPECTED_VERSION")

      true = version == expected_version
      true = metadata["name"] == Atom.to_string(app)
      true = config[:app] == app
      false = Enum.any?(metadata["requirements"], &(Map.new(&1)["name"] == "ex_doc"))

      for dependency <- metadata["requirements"],
          dependency = Map.new(dependency),
          dependency["name"] in ["arbor_rpc", "arbor_acp"] do
        dependency_app = String.to_atom(dependency["app"])

        target_version =
          System.get_env("ARCHIVE_EXPECTED_VERSION_#{String.upcase(dependency["app"])}") ||
            System.fetch_env!("ARCHIVE_EXPECTED_VERSION")

        target = Version.parse!(target_version)
        prerelease? = target.pre != []

        requirement =
          if prerelease?, do: "~> #{target_version}", else: "~> #{target.major}.#{target.minor}"

        true = dependency["requirement"] == requirement
        true = dependency["optional"] == false
        declared = Enum.find(config[:deps], &(elem(&1, 0) == dependency_app))
        true = elem(declared, 1) == requirement
        options = if tuple_size(declared) == 3, do: elem(declared, 2), else: []
        false = Keyword.has_key?(options, :path)
        true = Version.match?(target_version, requirement)
        false = Version.match?("#{target.major + 1}.0.0", requirement)
        false = Version.match?("#{target.major - 1}.9.9", requirement)

        true =
          Version.match?("#{target.major}.#{target.minor}.0-dev", requirement) ==
            (target_version == "#{target.major}.#{target.minor}.0-dev")

        true =
          Version.match?("#{target.major}.#{target.minor}.0-rc.999999", requirement) ==
            prerelease?
      end

      {:ex_doc, "~> 0.40", doc_options} = Enum.find(config[:deps], &(elem(&1, 0) == :ex_doc))
      :dev = doc_options[:only]
      false = doc_options[:runtime]
      false = Keyword.has_key?(doc_options, :path)

      ref = if app in [:arbor_mcp, :arbor_rpc], do: "v#{version}", else: "#{app}-v#{version}"
      true = config[:docs][:source_ref] == ref

      if app != :arbor_mcp do
        expected =
          if app == :arbor_rpc,
            do: "https://github.com/trust-arbor/arbor_rpc/blob/#{ref}/%{path}#L%{line}",
            else:
              "https://github.com/trust-arbor/arbor_acp/blob/#{ref}/packages/#{app}/%{path}#L%{line}"

        true = config[:docs][:source_url_pattern] == expected
      end

      IO.puts("Verified #{app}: literal/Hex #{version}, source ref #{ref}")
      version
    end)
  end

true = projects != []
