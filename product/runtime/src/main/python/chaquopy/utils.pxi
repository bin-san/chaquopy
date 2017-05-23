import six
from cpython.version cimport PY_MAJOR_VERSION

import chaquopy


def cast(cls, JavaObject obj):
    """Returns a view of the given object as the given class. Raises TypeError if the object is not
    assignable to the class.

    Situations where this could be useful:

    * By changing the apparent type of the object to one of its superclasses, a less specific
      overload may be chosen when passing the object to a method.
    * By removing visibility of a method's overloads added in a subclass, a superclass overload
      may be chosen instead when calling that method on the object.
    """
    if not isinstance(cls, JavaClass):
        raise TypeError(f"{type(cls).__name__} object is not a Java class")
    return cls(instance=obj.j_self)


# TODO #5167 this may fail in non-Java-created threads on Android, because they'll use the
# wrong ClassLoader.
def find_javaclass(name):
    """Returns the java.lang.Class proxy object corresponding to the given fully-qualified class
    name. Either '.' or '/' notation may be used. Raises the same exceptions as Class.forName.
    """
    return chaquopy.autoclass("java.lang.Class")(instance=CQPEnv().FindClass(name))


cdef str_for_c(s):
     if PY_MAJOR_VERSION < 3:
        if isinstance(s, unicode):
            return s.encode('utf-8')
        else:
            return s
     else:
        return s.encode('utf-8')


def parse_definition(definition):
    BAD_CHARS = ",."  # ',' should be ';' or nothing, and '.' should be '/'
    for c in BAD_CHARS:
        if c in definition:
            raise ValueError(f"Invalid character '{c}' in definition '{definition}'")

    # not a function, just a field
    if definition[0] != '(':
        return definition, None

    # it's a function!
    argdef, ret = definition[1:].split(')')
    args = []

    while len(argdef):
        c = argdef[0]

        # read the array char(s)
        prefix = ''
        while c == '[':
            prefix += c
            argdef = argdef[1:]
            c = argdef[0]

        # native type
        if c in 'ZBCSIJFD':
            args.append(prefix + c)
            argdef = argdef[1:]
            continue

        # java class
        if c == 'L':
            c, argdef = argdef.split(';', 1)
            args.append(prefix + c + ';')
            continue

        raise ValueError(f"Invalid type code '{c}' in definition '{definition}'")

    return ret, tuple(args)


cdef expect_exception(JNIEnv *j_env, msg):
    """Raises a Java exception if one is pending, otherwise raises a Python Exception with the
    given message.
    """
    check_exception(j_env)
    raise Exception(msg)

# To avoid recursion, this function must not use anything which could itself call check_exception.
cdef check_exception(JNIEnv *j_env):
    cdef jmethodID toString = NULL
    cdef jmethodID getCause = NULL
    cdef jmethodID getStackTrace = NULL
    cdef jmethodID getMessage = NULL
    cdef jstring e_msg
    cdef jthrowable exc = j_env[0].ExceptionOccurred(j_env)
    cdef jclass cls_object = NULL
    cdef jclass cls_throwable = NULL
    if exc:
        j_env[0].ExceptionClear(j_env)
        cls_object = j_env[0].FindClass(j_env, "java/lang/Object")
        cls_throwable = j_env[0].FindClass(j_env, "java/lang/Throwable")

        toString = j_env[0].GetMethodID(j_env, cls_object, "toString", "()Ljava/lang/String;");
        getMessage = j_env[0].GetMethodID(j_env, cls_throwable, "getMessage", "()Ljava/lang/String;");
        getCause = j_env[0].GetMethodID(j_env, cls_throwable, "getCause", "()Ljava/lang/Throwable;");
        getStackTrace = j_env[0].GetMethodID(j_env, cls_throwable, "getStackTrace", "()[Ljava/lang/StackTraceElement;");
        e_msg = j_env[0].CallObjectMethod(j_env, exc, getMessage);
        pymsg = "" if e_msg == NULL else j2p_string(j_env, e_msg)

        if j_env[0].ExceptionOccurred(j_env):
            raise JavaException("Another exception occurred while getting exception details")

        pystack = []
        _append_exception_trace_messages(j_env, pystack, exc, getCause, getStackTrace, toString)

        pyexcclass = lookup_java_object_name(j_env, exc)

        j_env[0].DeleteLocalRef(j_env, cls_object)
        j_env[0].DeleteLocalRef(j_env, cls_throwable)
        if e_msg != NULL:
            j_env[0].DeleteLocalRef(j_env, e_msg)
        j_env[0].DeleteLocalRef(j_env, exc)

        raise JavaException(f'{pyexcclass}: {pymsg}', pyexcclass, pymsg, pystack)


# FIXME #5179: this does not appear to work, I've never seen a Java stack trace on a JavaException,
# even in its description string.
cdef void _append_exception_trace_messages(
    JNIEnv*      j_env,
    list         pystack,
    jthrowable   exc,
    jmethodID    mid_getCause,
    jmethodID    mid_getStackTrace,
    jmethodID    mid_toString):

    # Get the array of StackTraceElements.
    cdef jobjectArray frames = j_env[0].CallObjectMethod(j_env, exc, mid_getStackTrace)
    cdef jsize frames_length = j_env[0].GetArrayLength(j_env, frames)
    cdef jstring msg_obj
    cdef jobject frame
    cdef jthrowable cause

    # Add Throwable.toString() before descending stack trace messages.
    if frames != NULL:
        msg_obj = j_env[0].CallObjectMethod(j_env, exc, mid_toString)
        pystr = None if msg_obj == NULL else j2p_string(j_env, msg_obj)
        # If this is not the top-of-the-trace then this is a cause.
        if len(pystack) > 0:
            pystack.append("Caused by:")
        pystack.append(pystr)
        if msg_obj != NULL:
            j_env[0].DeleteLocalRef(j_env, msg_obj)

    # Append stack trace messages if there are any.
    if frames_length > 0:
        for i in range(frames_length):
            # Get the string returned from the 'toString()' method of the next frame and append it to the error message.
            frame = j_env[0].GetObjectArrayElement(j_env, frames, i)
            msg_obj = j_env[0].CallObjectMethod(j_env, frame, mid_toString)
            pystr = None if msg_obj == NULL else j2p_string(j_env, msg_obj)
            pystack.append(pystr)
            if msg_obj != NULL:
                j_env[0].DeleteLocalRef(j_env, msg_obj)
            j_env[0].DeleteLocalRef(j_env, frame)

    # If 'exc' has a cause then append the stack trace messages from the cause.
    if frames != NULL:
        cause = j_env[0].CallObjectMethod(j_env, exc, mid_getCause)
        if cause != NULL:
            _append_exception_trace_messages(j_env, pystack, cause,
                                             mid_getCause, mid_getStackTrace, mid_toString)
            j_env[0].DeleteLocalRef(j_env, cause)

    j_env[0].DeleteLocalRef(j_env, frames)


# To avoid recursion, this function must not use anything which could call check_exception.
cdef lookup_java_object_name(JNIEnv *j_env, jobject j_obj):
    """Returns the fully-qualified class name of the given object, in the same format as
    Class.getName().
    * Array types are returned in JNI format (e.g. "[Ljava/lang/Object;" or "[I".
    * Other types are returned in Java format (e.g. "java.lang.Object"
    """
    # Can't call getClass() or getName() using autoclass because that'll cause a recursive call
    # when getting the returned object type.
    cdef jclass jcls = j_env[0].GetObjectClass(j_env, j_obj)
    cdef jclass jcls2 = j_env[0].GetObjectClass(j_env, jcls)
    cdef jmethodID jmeth = j_env[0].GetMethodID(j_env, jcls2, 'getName', '()Ljava/lang/String;')
    # Can't call check_exception because that'll cause a recursive call when getting the
    # exception type name.
    if jmeth == NULL:
        raise Exception("GetMethodID failed")
    cdef jobject js = j_env[0].CallObjectMethod(j_env, jcls, jmeth)
    if js == NULL:
        raise Exception("getName failed")

    name = j2p_string(j_env, js)
    j_env[0].DeleteLocalRef(j_env, js)
    j_env[0].DeleteLocalRef(j_env, jcls)
    j_env[0].DeleteLocalRef(j_env, jcls2)
    return name


def is_applicable(sign_args, args, *, varargs):
    if len(args) == len(sign_args):
        if len(args) == 0:
            return True
    elif varargs:
        if len(args) < len(sign_args) - 1:
            return False
    else:
        return False

    cdef JNIEnv *env = get_jnienv()
    for index, sign_arg in enumerate(sign_args):
        if varargs and index == len(sign_args) - 1:
            assert sign_arg[0] == "["
            arg = args[index:]
        else:
            arg = args[index]
        if not is_applicable_arg(env, sign_arg, arg):
            return False

    return True


# Because of the caching in JavaMultipleMethod, the result of this function must only be
# affected by the actual parameter types, not their values.
cdef is_applicable_arg(JNIEnv *env, r, arg):
    # FIXME in the case of a list/tuple, p2j will succeed or fail based on the types of the
    # values inside, but JavaMultipleMethod will cache based only on the container type. Make
    # it so that all lists/tuples are considered applicable to all arrays but never more
    # specific. They can be wrapped with jarray(type, obj), where type is a JavaClass,
    # primitive, or jarray(type). For caching to work, calls to jarray with different types
    # must return objects of different types.
    try:
        p2j(env, r, arg)
        return True
    except TypeError:
        return False


def better_overload(JavaMethod jm1, JavaMethod jm2, actual_types, *, varargs):
    """Returns whether jm1 is an equal or better match than jm2 for the given actual parameter
    types. This is based on JLS 15.12.2.5. "Choosing the Most Specific Method" and JLS 4.10.
    "Subtyping".
    """
    defs1, defs2 = jm1.definition_args, jm2.definition_args

    if varargs:
        return False  # FIXME
    else:
        return (len(defs1) == len(defs2) and
                all([better_overload_arg(d1, d2, at)
                     for d1, d2, at in six.moves.zip(defs1, defs2, actual_types)]))


# Because of the caching in JavaMultipleMethod, the result of this function must only be
# affected by the actual parameter types, not their values.
#
# We don't have to handle combinations which will be filtered out by is_applicable_arg. For
# example, we'll never be asked to compare a numeric type with a boolean or char, because any
# actual parameter type which is applicable to one will not be applicable to the others.
#
# In this context, boxed and unboxed types are NOT treated as related. The JLS requires an
# initial search for applicable overloads with boxing and unboxing disabled, but that's not
# relevant to us: see note about unboxing in p2j.
def better_overload_arg(def1, def2, actual_type):
    if def2 == def1:
        return True

    # To avoid data loss, we prefer to treat a Python int or float as the largest of the
    # corresponding Java types.
    elif issubclass(actual_type, six.integer_types) and (def1 in INT_TYPES) and (def2 in INT_TYPES):
        return INT_TYPES.find(def1) >= INT_TYPES.find(def2)
    elif issubclass(actual_type, float) and (def1 in FLOAT_TYPES) and (def2 in FLOAT_TYPES):
        return FLOAT_TYPES.find(def1) >= FLOAT_TYPES.find(def2)

    # Similarly, we prefer to treat a Python string as a Java String rather than a char or a
    # char array. (Its length cannot be taken into account: see note above about caching.)
    elif issubclass(actual_type, six.string_types) and \
         (def2 in ["C", "[C"]) and (def1 == "Ljava/lang/String;"):
        return True

    # Otherwise we prefer the smallest (i.e. most specific) Java type. This includes the case
    # of passing a Python int where float and double overloads exist: the float overload will
    # be called, just like in Java.
    elif (def1 in NUMERIC_TYPES) and (def2 in NUMERIC_TYPES):
        return NUMERIC_TYPES.find(def1) <= NUMERIC_TYPES.find(def2)

    elif def2.startswith("L"):
        if def1.startswith("L"):
            return find_javaclass(def2[1:-1]).isAssignableFrom(find_javaclass(def1[1:-1]))
        elif def1.startswith("["):
            return def2 in ["Ljava/lang/Object;", "Ljava/lang/Cloneable;", "Ljava/io/Serializable;"]
    elif def2.startswith("["):
            return (def2[1] not in PRIMITIVE_TYPES and
                    def1.startswith("[") and
                    better_overload_arg(def2[1:], def1[1:], None))

    return False

    # FIXME Child[] is more specific than Parent, and int is more specific than double, but
    # int[] is not more specific than double[] (neither is assignable to the other, or to
    # Object[], although both are assignable to Object itself).
    #
    # However, (int...) actualy is more specific than (double...), because in this case
    # assignability is checked on a parameter-by-parameter basis, including the possibility
    # that the more specific overload has more or fewer parameters than the other. Like
    # is_applicable, this method needs to be informed whether we to use varargs or not.
    # https://relaxbuddy.com/forum/thread/20288/bug-with-varargs-and-overloading
