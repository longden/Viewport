import Foundation
import WebKit

/// Replaces `navigator.geolocation` in the web pane with a simulated position.
/// With no override the page falls back to the real WebKit implementation.
enum WebGeolocationOverride {
    static func userScript(initial coordinate: GeoCoordinate?) -> WKUserScript {
        WKUserScript(
            source: source(initial: coordinate),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Moves the current document without a reload (route playback).
    static func updateScript(_ coordinate: GeoCoordinate?) -> String {
        "window.__viewportSetGeo && window.__viewportSetGeo(\(literal(coordinate)));"
    }

    static func literal(_ coordinate: GeoCoordinate?) -> String {
        guard let coordinate, coordinate.isValid else { return "null" }
        return "{latitude:\(GeoCoordinate.format(coordinate.latitude)),longitude:\(GeoCoordinate.format(coordinate.longitude))}"
    }

    static func source(initial coordinate: GeoCoordinate?) -> String {
        """
        (() => {
          if (window.__viewportGeoInstalled) return;
          window.__viewportGeoInstalled = true;
          const geo = navigator.geolocation;
          if (!geo) return;
          const state = { coord: \(literal(coordinate)), watchers: new Map(), nextId: 1 };
          const original = {
            get: geo.getCurrentPosition.bind(geo),
            watch: geo.watchPosition.bind(geo),
            clear: geo.clearWatch.bind(geo)
          };
          const position = (c) => {
            const coords = {
              latitude: c.latitude, longitude: c.longitude, accuracy: 5,
              altitude: null, altitudeAccuracy: null, heading: null, speed: null
            };
            coords.toJSON = () => ({ ...coords });
            const result = { coords, timestamp: Date.now() };
            result.toJSON = () => ({ coords: coords.toJSON(), timestamp: result.timestamp });
            return result;
          };
          geo.getCurrentPosition = function (success, error, options) {
            if (!state.coord) return original.get(success, error, options);
            const c = state.coord;
            setTimeout(() => { try { success(position(c)); } catch (_) {} }, 0);
          };
          // Every watch goes through here so it can move between the real feed
          // and the simulated one when the override is set or cleared.
          geo.watchPosition = function (success, error, options) {
            const id = 1000000 + state.nextId++;
            const entry = { success, error, options, realId: null };
            state.watchers.set(id, entry);
            if (state.coord) {
              const c = state.coord;
              setTimeout(() => { try { success(position(c)); } catch (_) {} }, 0);
            } else {
              entry.realId = original.watch(success, error, options);
            }
            return id;
          };
          geo.clearWatch = function (id) {
            const entry = state.watchers.get(id);
            if (!entry) return original.clear(id);
            state.watchers.delete(id);
            if (entry.realId !== null) original.clear(entry.realId);
          };
          window.__viewportSetGeo = (c) => {
            state.coord = c;
            for (const entry of state.watchers.values()) {
              if (c) {
                if (entry.realId !== null) {
                  original.clear(entry.realId);
                  entry.realId = null;
                }
                try { entry.success(position(c)); } catch (_) {}
              } else if (entry.realId === null) {
                entry.realId = original.watch(entry.success, entry.error, entry.options);
              }
            }
          };
        })();
        """
    }
}
