WORLD_UP :: Vector3.{0, 1, 0};
WRITE_DEBUG_RECORDS :: false;

Material :: struct
{
    using Kind :: enum
    {
        Opaque;
        Translucent;
        Emissive;
    }

    kind: Kind;

    ior      : float;
    metallic : float;
    color    : Vector3;
}

Primitive :: struct
{
    using Kind :: enum u16
    {
        None;
        Plane;
        Sphere;
        Box;
    }

    p: Vector3;
    dp: Vector3;

    material_index: s16;
    kind: Kind;
}

Plane :: struct
{
    using primitive: Primitive;
    kind = .Plane;

    n: Vector3;
}

Sphere :: struct
{
    using primitive: Primitive;
    kind = .Sphere;

    r: float;
}

Box :: struct
{
    using primitive: Primitive;
    kind = .Box;

    r: Vector3;
}

Camera :: struct
{
    p: Vector3;
    d: Vector3;
    prev_d: Vector3;
    fov: float; // vertical fov in degrees
}

basis_vectors :: (d: Vector3, up := WORLD_UP) -> x: Vector3, y: Vector3, z: Vector3
{
    z := -d;
    x := cross(up, z);
    y := cross(z, x);
    return x, y, z;
}

Ray :: struct
{
    o: Vector3;
    d: Vector3;
    inv_d: Vector3;
}

make_ray :: (o: Vector3, d: Vector3) -> Ray
{
    ray: Ray;
    ray.o = o;
    ray.d = d;
    ray.inv_d = 1.0 / d;
    return ray;
}

Scene :: struct
{
    time        : float;
    dt          : float;
    frame_index : int;

    sky_bot: Vector3;
    sky_top: Vector3;

    planes:    [..] Plane;
    spheres:   [..] Sphere;
    boxes:     [..] Box;
    materials: [..] Material;
    lights:    [..] *Primitive;

    debug_records: Intersect_Debug_Records;
}

Intersect_Record :: struct
{
    o:             Vector3;
    d:             Vector3;
    hit_p:         Vector3;
    hit_primitive: *Primitive;
}

Intersect_Records_Level :: struct
{
    hit:    [..] Intersect_Record;
    shadow: [..] Intersect_Record;
}

Intersect_Debug_Records :: struct
{
    current_level: int;
    levels: [256] Intersect_Records_Level;
}

add_primitive :: (using scene: *Scene, primitive: $T/Primitive)
{
    at: *Primitive;

    #if T == Sphere  
    {
        array_add(*spheres, primitive);
        at = *spheres[spheres.count - 1];
    }
    #if T == Box
    {
        array_add(*boxes, primitive);
        at = *boxes[boxes.count - 1];
    }
    #if T == Plane 
    {
        array_add(*planes, primitive);
        at = *planes[planes.count - 1];
    }

    material := *materials[primitive.material_index];
    if material.kind == .Emissive
    {
        array_add(*lights, at);
    }
}

add_material :: (using scene: *Scene, material: Material) -> s16
{
    result := cast(s16) materials.count;
    array_add(*materials, material);
    return result;
}

Tile :: struct
{
    x0: int;
    y0: int;
    x1: int;
    y1: int;
};

sample_blue_noise1 :: (frame_index: int, x: int, y: int) -> float
{
    bitmap := *g_blue_noise1[frame_index % g_blue_noise1.count];

    x_ := x & (bitmap.w - 1);
    y_ := y & (bitmap.h - 1);

    pix := bitmap.data.data + x_*3 + y_*bitmap.stride;
    r := << (pix + 0);

    return cast(float)r * (1.0/255.0);
}

sample_blue_noise3 :: (frame_index: int, x: int, y: int) -> Vector3
{
    bitmap := *g_blue_noise3[frame_index % g_blue_noise3.count];

    x_ := x & (bitmap.w - 1);
    y_ := y & (bitmap.h - 1);

    pix := bitmap.data.data + x_*3 + y_*bitmap.stride;
    r := << (pix + 0);
    g := << (pix + 1);
    b := << (pix + 2);

    PHI :: cast(float)1.618033988;

    offset := cast(float)(frame_index / g_blue_noise3.count) * PHI;

    color := make_vector3(
        frac(offset + cast(float)r * (1.0/255.0)),
        frac(offset + cast(float)g * (1.0/255.0)),
        frac(offset + cast(float)b * (1.0/255.0)),
    );

    return color;
}

render_scene :: (camera: Camera, scene: *Scene, acc: Accumulation_Buffer, tile: Tile)
{
    w := cast(float) acc.w;
    h := cast(float) acc.h;

    film_w := w / h;
    film_h := 1.0;

    half_film_w := 0.5*film_w;
    half_film_h := 0.5*film_h;

    inv_half_film_w := 1.0 / half_film_w;
    inv_half_film_h := 1.0 / half_film_h;

    pixel_w := 1.0 / w;
    pixel_h := 1.0 / h;

    film_distance := film_h / tan(to_radians(camera.fov));

    random: Random_Series;
    random.state = xx ((scene.frame_index + 1)*(tile.x1 + 1000*tile.y1));

    for y: tile.y0..tile.y1-1
    {
        v := 1.0 - 2.0*(cast(float) y / h);

        for x: tile.x0..tile.x1-1
        {
            u := -1.0 + 2.0*(cast(float) x / w);

            color: Vector3;

            SAMPLE_COUNT :: 1;

            for 0..SAMPLE_COUNT-1
            {
                camera_d := lerp(camera.d, camera.prev_d, random_unilateral(*random));
                camera_x, camera_y, camera_z := basis_vectors(camera_d);

                p := camera.p;

                film_o := -camera_z * film_distance;

                jitter_x := 0.5*random_bilateral(*random);
                jitter_y := 0.5*random_bilateral(*random);

                film_p := film_o;
                film_p += (u + pixel_w*jitter_x)*half_film_w*camera_x;
                film_p += (v + pixel_h*jitter_y)*half_film_h*camera_y;

                d := normalize(film_p);

                r := make_ray(p, d);

                color += integrate_scene(scene, r, *random, x, y);
            }
            color *= 1.0 / cast(float) SAMPLE_COUNT;

            << get_texel(acc, x, y) += make_vector4(color.x, color.y, color.z, 1);
        }
    }
}

MAX_BOUNCES :: 8;

integrate_scene :: (using scene: Scene, in_ray: Ray, random: *Random_Series, x: int, y: int) -> Vector3
{
    throughput := Vector3.{1, 1, 1};
    color      := Vector3.{0, 0, 0};

    ray := in_ray;
    last_vertex_specular := false;

    for 0..MAX_BOUNCES-1
    {
        t, primitive := intersect_scene(scene, ray, random);

        if primitive
        {
            hit_p  := ray.o + t*ray.d;
            n := inline get_normal(primitive, hit_p);

            material := *materials[primitive.material_index];

            if material.kind == .Emissive
            {
                // if last_vertex_specular
                {
                    color += throughput*material.color;
                }
                break;
            }

            brdf := material.color*(1.0 / PI);

            throughput *= brdf;

            cos_theta_i := -dot(ray.d, n);

            eta_i := 1.0; // air
            eta_t := material.ior;
            eta_i_over_eta_t := eta_i / eta_t;

            reflectance, cos_theta_t := fresnel_dielectric(cos_theta_i, eta_i, eta_t, eta_i_over_eta_t);

            e: Vector3;

            if frame_index < g_blue_noise3.count
            {
                e = sample_blue_noise3(frame_index, x, y);
            }
            else
            {
                e.x = random_unilateral(random);
                e.y = random_unilateral(random);
                e.z = random_unilateral(random);
            }

            if e.x < reflectance
            {
                last_vertex_specular = true;

                ray = make_ray(hit_p + EPSILON*n, reflect(ray.d, n));
            }
            else
            {
                last_vertex_specular = false;

                /*
                l_dir, l_normal, l_dist, l_area := random_point_on_light(scene, hit_p, random);
                if dot(n, l_dir) > 0.0 && dot(l_normal, -l_dir) > 0.0
                {
                    shadow_ray := make_ray(hit_p + EPSILON*n, l_dir);
                    shadow_t, shadow_primitive := intersect_scene(scene, shadow_ray, random, shadow_ray=true);
                    if !shadow_primitive
                    {
                        solid_angle := (dot(l_normal, -l_dir) * l_area) / (l_dist*l_dist);
                        color += material.color*solid_angle*brdf*dot(n, l_dir)*cast(float)lights.count;
                    }
                }
                */

                r := orient_around_normal(map_to_hemisphere(e.yz), n);

                ray = make_ray(hit_p + EPSILON*n, r);

                throughput *= dot(ray.d, n);
                throughput *= 2*PI;
            }
        }
        else
        {
            sky_col := lerp(sky_bot, sky_top, saturate(ray.d.y));

            color += throughput*sky_col;

            break;
        }
    }

    return color;
}

random_point_on_light :: (using scene: Scene, hit_p: Vector3, random: *Random_Series) -> l_dir: Vector3, l_normal: Vector3, l_dist: Vector3, l_area: float
{
    light := lights[random_choice(random, xx lights.count)];

    l_dir    : Vector3;
    l_normal : Vector3;
    l_dist   : Vector3;
    l_area   : float;

    towards_light := normalize(light.p - hit_p);

    if light.kind ==
    {
        case .Sphere;
            s := cast(*Sphere)light;
            l_normal = orient_around_normal(map_to_hemisphere(random_unilateral2(random)), -towards_light);
            l_p     := s.p + l_normal*s.r;
            l_dir    = normalize(l_p - hit_p);
            l_area   = 2.0*PI*s.r*s.r;
    }

    return l_dir, l_normal, l_dist, l_area;
}

intersect_scene :: (using scene: Scene, r: Ray, random: *Random_Series, $shadow_ray := false) -> float, *Primitive
{
    t := FLOAT32_MAX;

    primitive: *Primitive;

    for *p: planes
    {
        jitter_p := p.p - random_unilateral(random)*p.dp*dt;

        hit_t := inline intersect_plane(r, jitter_p, p.n);
        if hit_t < t
        {
            primitive = p;
            t = hit_t;

            #if shadow_ray  return t, primitive;
        }
    }

    for *s: spheres
    {
        jitter_p := s.p - random_unilateral(random)*s.dp*dt;

        hit_t := inline intersect_sphere(r, jitter_p, s.r);
        if hit_t < t
        {
            primitive = s;
            t = hit_t;

            #if shadow_ray  return t, primitive;
        }
    }

    for *b: boxes
    {
        jitter_p := b.p - random_unilateral(random)*b.dp*dt;

        hit_t := inline intersect_box(r, jitter_p - b.r, jitter_p + b.r);
        if hit_t < t
        {
            primitive = b;
            t = hit_t;

            #if shadow_ray  return t, primitive;
        }
    }

    #if WRITE_DEBUG_RECORDS
    {
        level := *debug_records.levels[debug_records.current_level];

        #if shadow_ray
        {
            records := *level.hit;
        }
        else
        {
            records := *level.shadow;
        }

        record := array_add(records);
        record.o             = r.o;
        record.d             = r.d;
        record.hit_p         = r.o + t*r.d;
        record.hit_primitive = primitive;
    }

    return t, primitive;
}

intersect_plane :: inline (r: Ray, p: Vector3, n: Vector3) -> float
{
    t := dot(n, p - r.o) / dot(n, r.d);
    if t > EPSILON  return t;
    else            return FLOAT32_MAX;
}

intersect_sphere :: inline (r: Ray, p: Vector3, radius: float) -> float
{
    m := r.o - p;
    b := dot(m, r.d);
    c := dot(m, m) - radius*radius;

    if c > 0.0 && b > 0.0 then return FLOAT32_MAX;

    discr := b*b - c;

    if discr < 0.0 then return FLOAT32_MAX;

    t := -b - square_root(discr);

    if t < 0.0 then t = 0.0;

    return t;
}

intersect_box :: inline (r: Ray, b_min: Vector3, b_max: Vector3) -> float
{
    tx1 := r.inv_d.x*(b_min.x - r.o.x);
    tx2 := r.inv_d.x*(b_max.x - r.o.x);
    
    t_min := Max(0.0, Min(tx1, tx2));
    t_max := Max(tx1, tx2);

    ty1 := r.inv_d.y*(b_min.y - r.o.y);
    ty2 := r.inv_d.y*(b_max.y - r.o.y);

    t_min = Max(t_min, Min(ty1, ty2));
    t_max = Min(t_max, Max(ty1, ty2));

    tz1 := r.inv_d.z*(b_min.z - r.o.z);
    tz2 := r.inv_d.z*(b_max.z - r.o.z);

    t_min = Max(t_min, Min(tz1, tz2));
    t_max = Min(t_max, Max(tz1, tz2));

    if t_max >= t_min return t_min;
    else              return FLOAT32_MAX;
}

get_normal :: inline (primitive: *Primitive, hit_p: Vector3) -> Vector3
{
    normal: Vector3 = ---;

    if primitive.kind ==
    {
        case .Plane;
            p := cast(*Plane) primitive;
            normal = p.n;

        case .Sphere;
            s := cast(*Sphere) primitive;
            normal = normalize(hit_p - s.p);

        case .Box;
            b := cast(*Box) primitive;
            rel_p := (hit_p - b.p) / b.r;

            e := 0;
            n := abs(rel_p);

            if n.y > n.component[e]  e = 1;
            if n.z > n.component[e]  e = 2;

            normal = make_vector3(0, 0, 0);
            normal.component[e] = sign_of(rel_p.component[e]);

        case;
            assert(false, "This shouldn't happen");
    }

    return normal;
}

fresnel_dielectric :: (cos_theta_i: float, eta_i: float, eta_t: float, eta_i_over_eta_t: float) -> reflectance: float, cos_theta_t: float
{
    // SOURCE: http://www.pbr-book.org/3ed-2018/Reflection_Models/Specular_Reflection_and_Transmission.html#fragment-ComputemonocosThetaTusingSnellslaw-0

    // NOTE: Compute cos_theta_t using snell's law
    sin_theta_i := square_root(max(0.0, 1.0 - cos_theta_i*cos_theta_i));
    sin_theta_t := eta_i_over_eta_t*sin_theta_i;
    cos_theta_t := square_root(max(0.0, 1.0 - sin_theta_t*sin_theta_t));

    // NOTE: Handle total internal reflection
    if sin_theta_t >= 1
    {
        return 1, cos_theta_t;
    }

    r_parallel      := (((eta_t*cos_theta_i) - (eta_i*cos_theta_t)) / ((eta_t*cos_theta_i) + (eta_i*cos_theta_t)));
    r_perpendicular := (((eta_i*cos_theta_i) - (eta_t*cos_theta_t)) / ((eta_i*cos_theta_i) + (eta_t*cos_theta_t)));

    result := 0.5*(r_parallel*r_parallel + r_perpendicular*r_perpendicular);
    return result, cos_theta_t;
}

#scope_file

EPSILON :: 0.0001;
