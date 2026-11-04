import {build} from 'esbuild';
await build({entryPoints:['web/main.js'],bundle:true,minify:true,outfile:'dist/editor.js',logLevel:'info'});
