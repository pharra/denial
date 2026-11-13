use super::*;
use x11rb::protocol::xproto::{ClipOrdering, ConfigureWindowAux, Rectangle};

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn create_window(
    connection: &RustConnection,
    parent: Window,
) -> Result<Window, Box<dyn std::error::Error>> {
    let window = connection.generate_id()?;
    connection
        .create_window(
            0,
            window,
            parent,
            0,
            0,
            1920,
            1080,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new(),
        )?
        .check()?;
    Ok(window)
}

fn dispatch(shapes: &mut InputShapes) -> TestResult {
    shapes.connection.get_input_focus()?.reply()?;
    while let Some(event) = shapes.connection.poll_for_event()? {
        if let Event::Error(error) = &event {
            return Err(format!("unexpected X11 protocol error: {error:?}").into());
        }
        shapes.handle_event(event)?;
    }
    Ok(())
}

fn assert_input_rectangles(
    shapes: &InputShapes,
    window: Window,
    expected: &[Rectangle],
) -> TestResult {
    let actual = shapes
        .connection
        .shape_get_rectangles(window, SK::INPUT)?
        .reply()?
        .rectangles;
    let coordinates = |rects: &[Rectangle]| {
        rects
            .iter()
            .map(|r| (r.x, r.y, r.width, r.height))
            .collect::<Vec<_>>()
    };
    assert_eq!(coordinates(&actual), coordinates(expected));
    Ok(())
}

fn rect(x: i16, y: i16, width: u16, height: u16) -> Rectangle {
    Rectangle {
        x,
        y,
        width,
        height,
    }
}

#[test]
#[ignore = "requires an X11 server; creates only unmapped windows"]
fn frame_preserves_client_input_holes_across_shape_and_lifecycle_changes() -> TestResult {
    let (connection, screen) = x11rb::connect(None)?;
    let root = connection.setup().roots[screen].root;
    let connection = Arc::new(connection);
    let frame = create_window(&connection, root)?;
    let client = create_window(&connection, frame)?;
    let mut shapes = InputShapes {
        connection: connection.clone(),
        frames: HashMap::new(),
    };

    // A pet may publish its shape before its initial map request. The frame
    // must start with that shape rather than a screen-sized input rectangle.
    let pet = rect(1200, 970, 100, 100);
    connection
        .shape_rectangles(
            SO::SET,
            SK::INPUT,
            ClipOrdering::UNSORTED,
            client,
            0,
            0,
            &[pet],
        )?
        .check()?;
    shapes.track(client, frame)?;
    assert_input_rectangles(&shapes, frame, &[pet])?;

    // Animate the pet, then make the entire window click-through. Use real
    // ShapeNotify events, including the empty region which must stay empty.
    let moved = rect(900, 800, 80, 90);
    connection
        .shape_rectangles(
            SO::SET,
            SK::INPUT,
            ClipOrdering::UNSORTED,
            client,
            0,
            0,
            &[moved],
        )?
        .check()?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, frame, &[moved])?;
    connection
        .shape_rectangles(
            SO::SET,
            SK::INPUT,
            ClipOrdering::UNSORTED,
            client,
            0,
            0,
            &[],
        )?
        .check()?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, frame, &[])?;

    // Input also respects the bounding shape, including when no explicit
    // input shape remains. Clearing both shapes restores ordinary windows.
    let body = rect(20, 30, 40, 50);
    connection
        .shape_mask(SO::SET, SK::INPUT, client, 0, 0, x11rb::NONE)?
        .check()?;
    connection
        .shape_rectangles(
            SO::SET,
            SK::BOUNDING,
            ClipOrdering::UNSORTED,
            client,
            0,
            0,
            &[body],
        )?
        .check()?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, frame, &[body])?;
    let input = rect(25, 35, 100, 100);
    connection
        .shape_rectangles(
            SO::SET,
            SK::INPUT,
            ClipOrdering::UNSORTED,
            client,
            0,
            0,
            &[input],
        )?
        .check()?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, frame, &[rect(25, 35, 35, 45)])?;
    connection
        .shape_mask(SO::SET, SK::BOUNDING, client, 0, 0, x11rb::NONE)?
        .check()?;
    connection
        .shape_mask(SO::SET, SK::INPUT, client, 0, 0, x11rb::NONE)?
        .check()?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, frame, &[rect(0, 0, 1920, 1080)])?;

    // Copying an implicit shape makes it explicit on the frame: a resize
    // must refresh it, or newly exposed parts stop receiving input.
    connection
        .configure_window(frame, &ConfigureWindowAux::new().width(2048).height(1200))?
        .check()?;
    connection
        .configure_window(client, &ConfigureWindowAux::new().width(2048).height(1200))?
        .check()?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, frame, &[rect(0, 0, 2048, 1200)])?;

    // Smithay destroys the frame on unmap. A later map of the same client
    // must update the new frame and leave the old resource alone.
    shapes.forget(client);
    connection
        .shape_rectangles(
            SO::SET,
            SK::INPUT,
            ClipOrdering::UNSORTED,
            client,
            0,
            0,
            &[pet],
        )?
        .check()?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, frame, &[rect(0, 0, 2048, 1200)])?;
    let next_frame = create_window(&connection, root)?;
    connection
        .reparent_window(client, next_frame, 0, 0)?
        .check()?;
    shapes.track(client, next_frame)?;
    dispatch(&mut shapes)?;
    assert_input_rectangles(&shapes, next_frame, &[pet])?;
    connection.destroy_window(frame)?.check()?;
    connection.destroy_window(next_frame)?.check()?;
    dispatch(&mut shapes)?;
    Ok(())
}
