//! Keep Smithay's reparenting frames out of an X11 client's input holes.
//!
//! Xwayland publishes the frame's Wayland input region, not the child's.
//! Copy shapes on the X server so animated input regions need no rectangle
//! downloads or work on the compositor's pointer-motion path.

use std::collections::HashMap;
use std::sync::Arc;

use smithay::utils::x11rb::X11Source;
use x11rb::connection::Connection;
use x11rb::errors::ConnectionError;
use x11rb::protocol::shape::{ConnectionExt as _, SK, SO};
use x11rb::protocol::xproto::{
    AtomEnum, ChangeWindowAttributesAux, ConnectionExt as _, CreateWindowAux, EventMask, Window,
    WindowClass,
};
use x11rb::protocol::{ErrorKind, Event};
use x11rb::rust_connection::RustConnection;

pub(super) struct InputShapes {
    connection: Arc<RustConnection>,
    frames: HashMap<Window, Window>,
}

impl InputShapes {
    pub(super) fn start(display: u32) -> Result<(Self, X11Source), Box<dyn std::error::Error>> {
        let (connection, screen) = x11rb::connect(Some(&format!(":{display}")))?;
        let version = connection.shape_query_version()?.reply()?;
        if (version.major_version, version.minor_version) < (1, 1) {
            return Err("Xwayland does not support SHAPE input regions".into());
        }
        let close_window = connection.generate_id()?;
        connection.create_window(
            0,
            close_window,
            connection.setup().roots[screen].root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_ONLY,
            0,
            &CreateWindowAux::new(),
        )?;
        connection.flush()?;
        let connection = Arc::new(connection);
        let source = X11Source::new(connection.clone(), close_window, AtomEnum::WM_NAME.into());
        Ok((
            Self {
                connection,
                frames: HashMap::new(),
            },
            source,
        ))
    }

    pub(super) fn track(&mut self, client: Window, frame: Window) -> Result<(), ConnectionError> {
        self.connection.shape_select_input(client, true)?;
        self.connection.change_window_attributes(
            client,
            &ChangeWindowAttributesAux::new().event_mask(EventMask::STRUCTURE_NOTIFY),
        )?;
        self.frames.insert(client, frame);
        self.synchronize(client, frame)
    }

    pub(super) fn forget(&mut self, client: Window) {
        self.frames.remove(&client);
    }

    pub(super) fn handle_event(&mut self, event: Event) -> Result<(), ConnectionError> {
        let client = match event {
            Event::ShapeNotify(event)
                if event.shape_kind == SK::INPUT || event.shape_kind == SK::BOUNDING =>
            {
                event.affected_window
            }
            // Default shapes grow on resize. ReparentNotify also closes the
            // race between Smithay creating a frame and this connection's
            // initial copy reaching the server.
            Event::ConfigureNotify(event) => event.window,
            Event::ReparentNotify(event) => event.window,
            Event::DestroyNotify(event) => {
                self.forget(event.window);
                return Ok(());
            }
            // A client or its old frame can disappear before queued requests
            // execute. The XWM lifecycle callbacks retire the mapping too.
            Event::Error(error) if error.error_kind == ErrorKind::Window => return Ok(()),
            Event::Error(error) => {
                tracing::warn!(?error, "Xwayland input shape request failed");
                return Ok(());
            }
            _ => return Ok(()),
        };
        if let Some(&frame) = self.frames.get(&client) {
            self.synchronize(client, frame)?;
        }
        Ok(())
    }

    fn synchronize(&self, client: Window, frame: Window) -> Result<(), ConnectionError> {
        self.connection
            .shape_combine(SO::SET, SK::INPUT, SK::INPUT, frame, 0, 0, client)?;
        // The effective input region is also clipped by the client's bounding
        // shape, even when it has never set an explicit input shape.
        self.connection.shape_combine(
            SO::INTERSECT,
            SK::INPUT,
            SK::BOUNDING,
            frame,
            0,
            0,
            client,
        )?;
        self.connection.flush()
    }
}

#[cfg(test)]
#[path = "input_shape/tests.rs"]
mod tests;
