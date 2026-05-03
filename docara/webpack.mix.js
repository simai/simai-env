const mix = require('laravel-mix');
const fs = require('fs');
require('laravel-mix-docara');

mix.disableSuccessNotifications();
mix.setPublicPath('source/assets/build');
mix.copy('source/_core/_assets/img', 'source/assets/build/img');
if (fs.existsSync('source/img')) {
    mix.copy('source/img', 'source/assets/build/img');
}
mix.copy(
    'node_modules/@fontsource-variable/inter/files',
    'source/assets/build/css/files'
);
mix.sass('source/_core/_assets/css/main.scss', 'css');

mix.webpackConfig({
    stats: {
        all: false,
    },
    watchOptions: {
        ignored: [
            'node_modules/**',
            'source/assets/build/**',
            'vendor/**',
            'build_local/**',
        ],
    },
});

mix
    .docara()
    .js('source/_core/_assets/js/main.js', 'js')
    .js('source/_core/_assets/js/turbo.js', 'js')
    .options({processCssUrls: false})
    .browserSync({
        server: 'build_local',
        files: ['build_local/**/*'],
        open: false,
    })
    .version();
