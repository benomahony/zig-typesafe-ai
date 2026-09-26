const tai = b.dependency("tai", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("tai", tai.module("tai"));
