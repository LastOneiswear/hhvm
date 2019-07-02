<?hh // partial
// generated by idl-to-hni.php

/* Used to represent the type of object returned by __FUNCTION_CREDENTIAL__
 */
<<__NativeData("FunctionCredential")>>
final class FunctionCredential {
  public final function __construct() {
    trigger_error("Can't create a FunctionCredential directly", E_ERROR);
  }

  /* @param mixed $name
   * @return mixed
   */
  public final function __get($name) {
    trigger_error(
      "FunctionCredential object cannot have properties",
      E_RECOVERABLE_ERROR
    );
  }

  /* @param mixed $name
   * @param mixed $value
   * @return mixed
   */
  public final function __set($name, $value) {
    trigger_error(
      "FunctionCredential object cannot have properties",
      E_RECOVERABLE_ERROR
    );
  }

  /* @param mixed $name
   * @return bool
   */
  public final function __isset($name) {
    trigger_error(
      "FunctionCredential object cannot have properties",
      E_RECOVERABLE_ERROR
    );
    return false;
  }

  /* @param mixed $name
   * @return mixed
   */
  public final function __unset($name) {
    trigger_error(
      "FunctionCredential object cannot have properties",
      E_RECOVERABLE_ERROR
    );
  }

  /* @return array
   */
  <<__Native>>
  public final function __debugInfo(): darray;
}
