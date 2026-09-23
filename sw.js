/*
  Uncle's Welding Works - service worker.
  Its only job: show the phone notification when Supabase push arrives,
  and open the job board when the welder taps it.
*/
self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function (event) {
  var data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { body: event.data ? event.data.text() : '' };
  }
  var title = data.title || "Uncle's Welding Works";
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || 'You have a new message.',
    icon: 'icons/icon-192.png',
    badge: 'icons/icon-192.png',
    tag: data.tag || 'uw-notice',
    data: { url: data.url || 'welder.html' }
  }));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var url = (event.notification.data && event.notification.data.url) || 'welder.html';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
      // The board already open somewhere? Bring it to the front.
      for (var i = 0; i < list.length; i++) {
        var c = list[i];
        if (c.url.indexOf('welder.html') > -1 && 'focus' in c) return c.focus();
      }
      // Otherwise open it.
      return self.clients.openWindow(url);
    })
  );
});
