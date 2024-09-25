import("core.tool.toolchain")

import("platform")
import("common")

local vstudio_url = "https://aka.ms/vs/17/release/vs_community.exe"
local vstudio_installer = "VisualStudioInstaller.exe"

local vstudio_installer_file = path.join(platform.get_config_info().rcachedir, vstudio_installer)
local vs_install_path = [["C:\Program Files\Microsoft Visual Studio\2022\Community"]]
local vs_cpp_components = "Microsoft.VisualStudio.Workload.NativeDesktop;" ..
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64;"


function installed()
    local version = nil
    if os.host() == "windows" then
        version = toolchain.load("msvc"):config("vs")
    elseif os.host() == "linux" then
    	-- cprint("[xlings]: vs not support for linux")
    else
        -- TODO
    end

    if version then
        cprint("vs ".. version)
        return true
    else
        return false
    end
end

function install()

    if os.host() ~= "windows" then
        cprint("[xlings]: not support install visual studio for other platform")
        return
    end

    cprint("[xlings]: install visual studio...")

    if not os.isfile(vstudio_installer_file) then
        common.xlings_download(vstudio_url, vstudio_installer_file)
    end

    return try {
        function ()
            common.xlings_exec(
                vstudio_installer_file ..
                --" start /b \"\" " ..
                -- " --installPath " .. vs_install_path ..
                " --add " .. vs_cpp_components ..
                " --includeRecommended" ..
                -- " --quiet " ..
                " --passive " ..
                -- " --norestart " ..
                " --wait " -- ..
            )
            return true
        end, catch {
            function (e)
                os.tryrm(vstudio_installer_file)
                return false
            end
        }
    }
end