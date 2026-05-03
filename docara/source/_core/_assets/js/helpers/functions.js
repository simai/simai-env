export default function  setReadModePosition(container, readModeButton) {
    const mainRect = container.getBoundingClientRect();
    const sideWidth = readModeButton.offsetParent
        ? readModeButton.clientWidth
        : readModeButton.getBoundingClientRect().width;

    const menuOffset = mainRect.left + container.clientWidth + sideWidth + 16;

    const viewportWidth = document.documentElement.clientWidth;
    const setInside = menuOffset >= viewportWidth;
    if(container.classList.contains('read')) {
        if (setInside) {
            if(container.contains(readModeButton)) return;
            readModeButton.classList.add('inside');
            container.append(readModeButton);
        } else {
            if(container.contains(readModeButton)) {
                container.parentNode.append(readModeButton);
            }
            readModeButton.classList.remove('inside');
        }
    } else {
        if (setInside) {
            if(!container.contains(readModeButton)) {
                container.append(readModeButton);
            }
            readModeButton.classList.add('inside');
        } else {
            readModeButton.classList.remove('inside');
        }
    }
}
