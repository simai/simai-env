const fs = require('fs');
const path = require('path');

const filesToCopy = [
    'webpack.mix.js',
    'bootstrap.php',
    'translate.config.php',
    'eslint.config.js',
    'package.json'
];

const filesToSource = [
  '404.blade.php',
  'favicon.ico'
];
filesToSource.forEach(file => {
    const src = path.resolve(__dirname, file);
    const dest = path.resolve(`${process.cwd()}/source`, file);

    if (fs.existsSync(src)) {
        fs.copyFileSync(src, dest);
        console.log(`✔ copied ${file}`);
    } else {
        console.warn(`⚠ ${file} not found in _core`);
    }
});
filesToCopy.forEach(file => {
    const src = path.resolve(__dirname, file);
    const dest = path.resolve(process.cwd(), file);

    if (fs.existsSync(src)) {
        fs.copyFileSync(src, dest);
        console.log(`✔ copied ${file}`);
    } else {
        console.warn(`⚠ ${file} not found in _core`);
    }
});
