window.addEventListener('DOMContentLoaded', function() {
    var frame = document.createElement('div');
    frame.id = 'viewport-frame';

    // Move all body children into the frame
    while (document.body.firstChild) {
        frame.appendChild(document.body.firstChild);
    }
    document.body.appendChild(frame);
});
