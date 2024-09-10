target("pylings-demo")
    set_kind("phony")
    add_files("tests/pylings-demo.py")
    add_files("exercises/pylings.py")
    on_run(function (target)
        os.exec("python3 " .. os.scriptdir() .. "/tests/pylings-demo.py")
    end)