function toggleSfFolder(item) {
    const parent = item.parentNode;
    if (parent && parent.classList.contains('sf-folder')) {
        parent.classList.toggle('open');
    }
}
