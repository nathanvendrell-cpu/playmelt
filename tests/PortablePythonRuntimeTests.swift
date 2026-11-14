import Foundation
import Darwin

@main enum PortablePythonRuntimeTests {
    static var checks=0
    static let fm=FileManager.default
    static func expect(_ value:Bool,_ label:String){checks+=1;if !value{fputs("FAIL: "+label+"\n",stderr);exit(1)}}
    static func put(_ value:Data,at url:URL,executable:Bool=false)throws{
        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try value.write(to:url);try fm.setAttributes([.posixPermissions:executable ? 0o700:0o600],ofItemAtPath:url.path)
    }
    static func staticPython(_ modules:[String], undefined:Set<String>=[], oversized:Bool=false)->Data {
        func bytes(_ value:UInt32)->[UInt8]{(0..<4).map{UInt8(truncatingIfNeeded:value >> ($0*8))}}
        var strings:[UInt8]=[0],symbols:[UInt8]=[]
        for module in modules {
            symbols += bytes(UInt32(strings.count)) + [undefined.contains(module) ? 1:15,1,0,0] + [1,0,0,0,0,0,0,0]
            strings += Array(("_PyInit_"+module).utf8) + [0]
        }
        let header:[UInt32]=[0xfeedfacf,0x0100000c,0,2,1,24,0,0]
        let command:[UInt32]=[2,24,56,UInt32(modules.count),UInt32(56+symbols.count),oversized ? UInt32.max:UInt32(strings.count)]
        return Data(header.flatMap(bytes)+command.flatMap(bytes)+symbols+strings)
    }
    static func main()throws{
        let root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/portable-python-fixtures-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
        let resources=root.appendingPathComponent("App with spaces.app/Contents/Resources"),python=resources.appendingPathComponent("Python"),library=python.appendingPathComponent("lib/python3.13")
        let executable=python.appendingPathComponent("bin/python3.13"),host=root.appendingPathComponent("Host/bin/python3")
        let header=Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0,2,0,0,0])
        try put(header,at:executable,executable:true);try put(Data("host fixture never executed".utf8),at:host,executable:true)
        try fm.createSymbolicLink(atPath:python.appendingPathComponent("bin/python3").path,withDestinationPath:"python3.13")
        for path in ["encodings/__init__.py","json/__init__.py","ssl.py","hashlib.py","urllib/request.py","importlib/metadata/__init__.py","ctypes/__init__.py"]{try put(Data("# fixture".utf8),at:library.appendingPathComponent(path))}
        for module in ["_ssl","_socket","_ctypes","_hashlib"]{try put(Data("module presence fixture".utf8),at:library.appendingPathComponent("lib-dynload/"+module+".cpython-313-darwin.so"))}
        let ca=library.appendingPathComponent("site-packages/certifi/cacert.pem")
        try put(Data("certificate presence fixture; never used for TLS".utf8),at:ca)
        for path in ["legendary/__init__.py","legendary/cli.py","requests/__init__.py"]{try put(Data("# fixture".utf8),at:library.appendingPathComponent("site-packages/"+path))}
        let metadata=library.appendingPathComponent("site-packages/legendary_gl-0.21.1.dist-info/METADATA")
        try put(Data("Name: legendary-gl\nVersion: 0.21.1\n\nfixture".utf8),at:metadata)
        try put(Data("#!/bin/sh\nexit 99\n".utf8),at:python.appendingPathComponent("bin/legendary"),executable:true)
        func resolve(_ development:Bool=false)->PortablePythonRuntime?{PortablePythonRuntime.resolve(resourcesURL:resources,development:development,developmentCandidates:[host],requireLegendary:true,requireCertificates:true)}
        let selected=resolve()!
        expect(selected.isBundled && selected.pythonURL==executable,"embedded arm64 runtime preferred with internal relative link and spaces")
        expect(selected.legendaryExecutableURL==python.appendingPathComponent("bin/legendary"),"portable Legendary wrapper selected")
        expect(selected.certificateURL==ca,"certifi bundle CA selected")
        let environment=selected.environment(merging:["PATH":"/opt/homebrew/bin","PYTHONHOME":"/outside","PYTHONPATH":"/outside","PYTHONUSERBASE":"/outside","SSL_CERT_FILE":"/outside/ca","REQUESTS_CA_BUNDLE":"/outside/requests-ca","KEEP":"yes"])
        expect(environment["SSL_CERT_FILE"]==ca.path && environment["REQUESTS_CA_BUNDLE"]==nil,"trusted bundle CA replaces inherited certificate override")
        expect(environment["PYTHONHOME"]==nil && environment["PYTHONPATH"]==nil && environment["PYTHONUSERBASE"]==nil,"portable process cannot import host Python configuration")
        expect(environment["PATH"]==executable.deletingLastPathComponent().path+":/usr/bin:/bin:/usr/sbin:/sbin" && environment["KEEP"]=="yes","bundled bin and system tools only, other required environment retained")
        expect(environment["PYTHONDONTWRITEBYTECODE"]=="1","workers never create bytecode in the bundle")
        try fm.removeItem(at:library.appendingPathComponent("encodings/__init__.py"))
        expect(resolve()==nil,"incomplete stdlib cannot fall back to the available host in release")
        try put(Data("# restored fixture".utf8),at:library.appendingPathComponent("encodings/__init__.py"))
        try put(Data("Name: legendary-gl\nVersion: 0.21.0\n".utf8),at:metadata)
        expect(resolve()==nil,"wrong Legendary version refused")
        expect(PortablePythonRuntime.resolve(resourcesURL:resources,development:false,requireCertificates:true) != nil,"Steam and graphics do not depend on Legendary availability")
        try put(Data("Name: legendary-gl\nVersion: 0.21.1\n".utf8),at:metadata)
        try put(Data(),at:ca);expect(resolve()==nil,"empty CA bundle refused for network workers")
        expect(PortablePythonRuntime.resolve(resourcesURL:resources,development:false) != nil,"non-network graphics helper needs no CA bundle")
        try put(Data("certificate fixture".utf8),at:ca)
        let link=python.appendingPathComponent("bin/python3")
        try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:host.path)
        expect(resolve()==nil,"external interpreter link refused despite executable host")
        try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:"python3")
        expect(resolve()==nil,"link cycle refused")
        try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:"python3.13")
        var x86=header;x86[4]=7;try put(x86,at:executable,executable:true)
        expect(resolve()==nil,"non-arm64 interpreter refused")
        try put(header,at:executable,executable:true)
        let modules=["_ssl","_socket","_ctypes","_hashlib"]
        try fm.removeItem(at:library.appendingPathComponent("lib-dynload"))
        try put(staticPython(modules),at:executable,executable:true)
        expect(resolve()?.isBundled==true,"standalone interpreter with all four defined builtin symbols needs no lib-dynload extensions")
        expect(resolve()?.isBundled==true,"repeated static-module resolution uses the same verified file identity")
        try put(staticPython(modules,undefined:["_ssl"]),at:executable,executable:true)
        expect(resolve()==nil,"rewrite invalidates cache and an undefined PyInit import is not a builtin")
        try put(staticPython(["_socket","_ctypes","_hashlib","_ssl_fake"]),at:executable,executable:true)
        expect(resolve()==nil,"similar symbol names do not satisfy an absent module")
        try put(Data(header+Data("_PyInit__ssl\0_PyInit__socket\0_PyInit__ctypes\0_PyInit__hashlib\0".utf8)),at:executable,executable:true)
        expect(resolve()==nil,"raw symbol strings without a valid Mach-O symbol table are refused")
        try put(staticPython(modules,oversized:true),at:executable,executable:true)
        expect(resolve()==nil,"unbounded Mach-O string tables are refused without allocating them")
        var truncated=staticPython(modules);truncated.removeLast()
        try put(truncated,at:executable,executable:true)
        expect(resolve()==nil,"truncated symbol tables are refused")
        try put(staticPython(["_socket","_ctypes","_hashlib"]),at:executable,executable:true)
        try put(Data("mixed dynamic module fixture".utf8),at:library.appendingPathComponent("lib-dynload/_ssl.cpython-313-darwin.so"))
        expect(resolve()?.isBundled==true,"a standalone may combine defined builtins and confined dynamic extensions")
        try fm.removeItem(at:library.appendingPathComponent("lib-dynload"))
        try put(staticPython(modules),at:executable,executable:true)
        try put(Data(),at:ca);expect(resolve()==nil,"static modules cannot excuse an empty required CA bundle")
        try put(Data("certificate fixture".utf8),at:ca)
        try fm.removeItem(at:library.appendingPathComponent("encodings/__init__.py"))
        expect(resolve()==nil,"static modules cannot excuse missing standard-library files")
        try put(Data("# restored fixture".utf8),at:library.appendingPathComponent("encodings/__init__.py"))
        let moved=root.appendingPathComponent("Moved app with spaces.app")
        try fm.moveItem(at:root.appendingPathComponent("App with spaces.app"),to:moved)
        let relocated=PortablePythonRuntime.resolve(resourcesURL:moved.appendingPathComponent("Contents/Resources"),development:false,requireLegendary:true,requireCertificates:true)
        expect(relocated?.pythonURL.path.hasPrefix(moved.path)==true && relocated?.certificateURL?.path.hasPrefix(moved.path)==true,"relocation needs neither old absolute paths nor host tools")
        let missing=root.appendingPathComponent("Missing Resources")
        expect(PortablePythonRuntime.resolve(resourcesURL:missing,development:false,developmentCandidates:[host])==nil,"release does not probe or use host candidates")
        expect(PortablePythonRuntime.resolve(resourcesURL:missing,development:true,developmentCandidates:[host])?.pythonURL==host,"explicit development alone retains supplied legacy fallback")
        expect(!fm.fileExists(atPath:python.path),"old runtime path no longer exists after relocation")
        let contents=moved.appendingPathComponent("Contents"),movedResources=contents.appendingPathComponent("Resources"),main=contents.appendingPathComponent("MacOS/MetalMax"),helper=movedResources.appendingPathComponent("m3-private-plan")
        let info:[String:Any]=["CFBundleIdentifier":"com.robtech.metalmaxgaminghub","CFBundleExecutable":"MetalMax","PlaymeltDevelopmentBuild":false]
        try put(try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0),at:contents.appendingPathComponent("Info.plist"))
        try put(header,at:main,executable:true);try put(header,at:helper,executable:true)
        try put(Data("# import fixture".utf8),at:movedResources.appendingPathComponent("local_game_import.py"))
        expect(PortablePythonRuntime.applicationResources(executableURL:main)==movedResources,"main executable finds only its own Playmelt resources")
        expect(PortablePythonRuntime.applicationResources(executableURL:helper)==movedResources,"nested m3-private-plan finds the same outer app resources")
        expect(PortablePythonRuntime.resource(named:"local_game_import.py",executableURL:helper)==movedResources.appendingPathComponent("local_game_import.py"),"nested helper also resolves its bundled Python script")
        expect(PortablePythonRuntime.resource(named:"../outside.py",executableURL:helper)==nil,"script resource cannot escape the same bundle")
        expect(PortablePythonRuntime.applicationResources(executableURL:movedResources.appendingPathComponent("other-tool"))==nil,"arbitrary tools do not trigger parent-directory searching")
        expect(PortablePythonRuntime.applicationResources(executableURL:host)==nil,"host tool cannot discover a nearby app runtime")
        var foreign=info;foreign["CFBundleIdentifier"]="other.application"
        try put(try PropertyListSerialization.data(fromPropertyList:foreign,format:.xml,options:0),at:contents.appendingPathComponent("Info.plist"))
        expect(PortablePythonRuntime.applicationResources(executableURL:helper)==nil,"another app identity is refused")
        expect(PortablePythonRuntime.allowsDevelopment(info:["PlaymeltDevelopmentBuild":true]),"only explicit development enables legacy candidates")
        expect(!PortablePythonRuntime.allowsDevelopment(info:["PlaymeltDevelopmentBuild":true,"PlaymeltInternalBuild":true]),"internal owner cannot enable host fallback")
        expect(PortablePythonRuntime.epicDevelopmentCandidates(projectRoot:root,applicationSupport:root,development:false).isEmpty,"release does not even construct legacy Epic venv candidates")
        if let index=CommandLine.arguments.firstIndex(of:"--signed-resources"),index+1<CommandLine.arguments.count {
            let actual=URL(fileURLWithPath:CommandLine.arguments[index+1]).standardizedFileURL
            let runtime=PortablePythonRuntime.resolve(resourcesURL:actual,development:false,requireLegendary:true,requireCertificates:true)
            expect(runtime?.isBundled==true,"signed Products runtime with statically linked modules passes filesystem preflight")
            expect(runtime?.pythonURL.path.hasPrefix(actual.appendingPathComponent("Python").path+"/")==true,"signed runtime interpreter stays inside its own bundle")
            let dynamic=actual.appendingPathComponent("Python/lib/python3.13/lib-dynload")
            let names=(try?fm.contentsOfDirectory(atPath:dynamic.path)) ?? []
            expect(!modules.contains{module in names.contains{$0.hasPrefix(module+".") && $0.hasSuffix(".so")}},"real signed fixture exercises static modules rather than dynamic fallbacks")
            expect(runtime?.certificateURL != nil && runtime?.legendaryExecutableURL != nil,"signed standalone retains certificate and Legendary requirements")
        }
        print("Portable Python runtime: \(checks) PASS; filesystem reads only, no interpreter, worker, network, account, Keychain or game executed.")
    }
}
